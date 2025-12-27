import Foundation
import UIKit
import CoreML
import Vision
import ZIPFoundation
#if canImport(StableDiffusion)
import StableDiffusion
#endif

// MARK: - Model Structures
struct StableDiffusionModel: Identifiable, Codable {
    let id: String
    let name: String
    let description: String
    let size: String
    let downloadUrl: String
}

// MARK: - Error Types
enum StableDiffusionError: Error, LocalizedError {
    case modelNotFound
    case pipelineNotInitialized
    case generationFailed
    
    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Stable Diffusion model resources not found. Please download the model files."
        case .pipelineNotInitialized:
            return "Stable Diffusion pipeline not initialized."
        case .generationFailed:
            return "Image generation failed."
        }
    }
}

// MARK: - Stable Diffusion Service
class StableDiffusionService {
    static let shared = StableDiffusionService()
    
    private init() {}
    
    struct GenerationSettings: Codable {
        var stepCount: Int = 25
        var guidanceScale: Float = 7.5
        var negativePrompt: String = ""
        var sampler: String = "default"
        var imageCount: Int = 1
        var previewLatent: Bool = false
        var previewDenoised: Bool = true
        var reduceMemory: Bool = false
        // computeUnits: "cpuAndNeural", "cpuAndGPU", "all"
        var computeUnits: String = "all"
        var seed: UInt32 = 0 // 0 means random

        // Optional post-process upscaler identifier (e.g., "realesrgan")
        // Presence of a value will trigger a simple 2× upscale pass for now.
        var upscalerId: String? = nil
    }
    
    static let progressNotification = Notification.Name("SDProgressImage")
    static let bytesNotification = Notification.Name("ModelDownloadBytes")
    static let unzipStartedNotification = Notification.Name("ModelUnzipStarted")
    static let unzipFinishedNotification = Notification.Name("ModelUnzipFinished")
    static let unzipProgressNotification = Notification.Name("ModelUnzipProgress")
    
    // Downscale helper to reduce memory while previewing frames
    private static func downscaledUIImage(from cgImage: CGImage, maxDimension: CGFloat) -> UIImage {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let scale = min(1.0, maxDimension / max(width, height))
        if scale >= 1.0 { return UIImage(cgImage: cgImage) }
        let newSize = CGSize(width: width * scale, height: height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { ctx in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
    
    // MARK: - Image Generation
    func generateImage(from drawing: UIImage) async throws -> UIImage {
        // For now, we'll simulate image generation from drawing
        // In a real implementation, this would use img2img capabilities
        try await Task.sleep(nanoseconds: 2_000_000_000) // Simulate processing time
        
        // Create a simple processed version of the drawing
        return processDrawing(drawing)
    }
    
    func generateImage(from prompt: String) async throws -> UIImage {
        try await generateImage(from: prompt, settings: nil)
    }
    
    func generateImage(from prompt: String, settings: GenerationSettings?) async throws -> UIImage {
        print("🎨 Generating image for prompt: \(prompt)")
        
        guard let active = ModelStorage.shared.getActiveModelResourcesURL() else {
            throw StableDiffusionError.modelNotFound
        }

#if canImport(StableDiffusion)
        return try await generateImageWithApplePipeline(prompt: prompt, resourcesURL: active, settings: settings)
#else
        return try await generateImageWithCoreML(prompt: prompt, modelPath: active)
#endif
    }
    
    private func generateImageWithCoreML(prompt: String, modelPath: URL) async throws -> UIImage {
        return try await withCheckedThrowingContinuation { continuation in
            generateImage(prompt: prompt, modelPath: modelPath) { cgImage in
                if let cgImage = cgImage {
                    let uiImage = UIImage(cgImage: cgImage)
                    let resized = Self.resizeUIImage(uiImage, to: CGSize(width: 512, height: 512))
                    continuation.resume(returning: resized)
                } else {
                    continuation.resume(throwing: StableDiffusionError.generationFailed)
                }
            }
        }
    }

#if canImport(StableDiffusion)
    private func generateImageWithApplePipeline(prompt: String, resourcesURL: URL, settings: GenerationSettings?) async throws -> UIImage {
        var pipeline: StableDiffusionPipeline? = nil
        let config = MLModelConfiguration()
        if let pref = settings?.computeUnits {
            switch pref {
            case "cpuAndNeural": config.computeUnits = .cpuAndNeuralEngine
            case "cpuAndGPU": config.computeUnits = .cpuAndGPU
            default: config.computeUnits = .all
            }
        } else {
            config.computeUnits = settings?.reduceMemory == true ? .cpuAndGPU : .all
        }
        // Reduce HTTP/URL caching pressure
        URLCache.shared.removeAllCachedResponses()
        URLCache.shared.memoryCapacity = 0
        URLCache.shared.diskCapacity = 0
        pipeline = try StableDiffusionPipeline(resourcesAt: resourcesURL, controlNet: [], configuration: config)
        try pipeline?.loadResources()
        defer { try? pipeline?.unloadResources() }
        var pConfig = StableDiffusionPipeline.Configuration(prompt: prompt)
        pConfig.stepCount = settings?.stepCount ?? 25
        pConfig.guidanceScale = settings?.guidanceScale ?? 7.5
        // Force single image when memory constrained
        pConfig.imageCount = (settings?.reduceMemory == true) ? 1 : (settings?.imageCount ?? 1)
        if let neg = settings?.negativePrompt, !neg.isEmpty { pConfig.negativePrompt = neg }
        // Best-effort sampler hint (no public API yet)
        _ = settings?.sampler
        let images = try pipeline!.generateImages(configuration: pConfig) { progress in
            // Throttle preview to every 2 steps for better UI performance
            if progress.step % 2 == 0, let cg = progress.currentImages.first ?? nil {
                autoreleasepool {
                    let ui = Self.downscaledUIImage(from: cg, maxDimension: 512)
                    NotificationCenter.default.post(name: StableDiffusionService.progressNotification, object: nil, userInfo: ["image": ui, "step": progress.step])
                }
            }
            return true
        }
        guard let maybeFirst = images.first, let first = maybeFirst else { throw StableDiffusionError.generationFailed }
        let baseImage = UIImage(cgImage: first)
        let resizedBase = Self.resizeUIImage(baseImage, to: CGSize(width: 512, height: 512))

        // Optional simple upscaler pass (placeholder)
        if let upId = settings?.upscalerId, !upId.isEmpty {
            if let upscaled = simpleUpscale(image: resizedBase, scale: 2.0) {
                return upscaled
            }
        }
        return resizedBase
    }
#endif
    
    private func generateImage(prompt: String, modelPath: URL, completion: @escaping (CGImage?) -> Void) {
        // Load compiled model from Documents directory
        guard let model = try? MLModel(contentsOf: modelPath) else {
            print("Failed to load model from: \(modelPath.path)")
            completion(nil)
            return
        }

        // Prepare inputs
        guard let input = try? MLDictionaryFeatureProvider(dictionary: [
            "prompt": prompt,
            "num_inference_steps": 25,
            "guidance_scale": 7.5
        ]) else {
            print("Failed to construct model input")
            completion(nil)
            return
        }

        guard let prediction = try? model.prediction(from: input) else {
            print("Failed to generate image")
            completion(nil)
            return
        }

        if let imageFeature = prediction.featureValue(for: "image"),
           let imageBuffer = imageFeature.imageBufferValue {
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            let context = CIContext()
            if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                completion(cgImage)
                return
            }
        }

        completion(nil)
    }
    
    
    private func generateImageLocally(prompt: String) async throws -> UIImage {
        // Simulate realistic processing time
        let processingTime = UInt64.random(in: 3_000_000_000...8_000_000_000) // 3-8 seconds
        try await Task.sleep(nanoseconds: processingTime)
        
        // Create a more sophisticated image based on the prompt
        return createAdvancedImage(for: prompt)
    }
    
    private func createAdvancedImage(for prompt: String) -> UIImage {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            // Create a more sophisticated background
            let colors = generateAdvancedColorsFromPrompt(prompt)
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
            
            // Use radial gradient for more interesting backgrounds
            context.cgContext.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: size.width/2, y: size.height/2),
                startRadius: 0,
                endCenter: CGPoint(x: size.width/2, y: size.height/2),
                endRadius: size.width/2,
                options: []
            )
            
            // Add more sophisticated visual elements
            addAdvancedVisualElements(context: context, prompt: prompt, size: size)
            
            // Add a subtle watermark
            let watermark = "AI Generated"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.6)
            ]
            
            let textSize = watermark.size(withAttributes: attributes)
            let textRect = CGRect(
                x: size.width - textSize.width - 16,
                y: size.height - textSize.height - 16,
                width: textSize.width,
                height: textSize.height
            )
            
            watermark.draw(in: textRect, withAttributes: attributes)
        }
    }
    
    private func generateAdvancedColorsFromPrompt(_ prompt: String) -> [CGColor] {
        let lowercased = prompt.lowercased()
        
        if lowercased.contains("sunset") || lowercased.contains("sunrise") {
            return [UIColor.systemOrange.cgColor, UIColor.systemPink.cgColor, UIColor.systemPurple.cgColor, UIColor.systemRed.cgColor]
        } else if lowercased.contains("ocean") || lowercased.contains("sea") || lowercased.contains("water") {
            return [UIColor.systemBlue.cgColor, UIColor.systemCyan.cgColor, UIColor.systemTeal.cgColor, UIColor.systemIndigo.cgColor]
        } else if lowercased.contains("forest") || lowercased.contains("tree") || lowercased.contains("nature") {
            return [UIColor.systemGreen.cgColor, UIColor.systemMint.cgColor, UIColor.systemTeal.cgColor, UIColor.systemBrown.cgColor]
        } else if lowercased.contains("fire") || lowercased.contains("flame") || lowercased.contains("red") {
            return [UIColor.systemRed.cgColor, UIColor.systemOrange.cgColor, UIColor.systemYellow.cgColor, UIColor.systemPink.cgColor]
        } else if lowercased.contains("space") || lowercased.contains("galaxy") || lowercased.contains("star") {
            return [UIColor.black.cgColor, UIColor.systemPurple.cgColor, UIColor.systemBlue.cgColor, UIColor.systemIndigo.cgColor]
        } else if lowercased.contains("abstract") || lowercased.contains("art") {
            return [UIColor.systemPurple.cgColor, UIColor.systemPink.cgColor, UIColor.systemBlue.cgColor, UIColor.systemCyan.cgColor]
        } else {
            return [UIColor.systemBlue.cgColor, UIColor.systemPurple.cgColor, UIColor.systemPink.cgColor, UIColor.systemCyan.cgColor]
        }
    }
    
    private func addAdvancedVisualElements(context: UIGraphicsImageRendererContext, prompt: String, size: CGSize) {
        let lowercased = prompt.lowercased()
        
        // Add multiple layers of visual elements
        addGeometricShapes(context: context, prompt: lowercased, size: size)
        addPatterns(context: context, prompt: lowercased, size: size)
        addSpecialEffects(context: context, prompt: lowercased, size: size)
    }
    
    private func addGeometricShapes(context: UIGraphicsImageRendererContext, prompt: String, size: CGSize) {
        // Add multiple geometric shapes
        if prompt.contains("circle") || prompt.contains("round") {
            for _ in 0..<3 {
                let x = CGFloat.random(in: 0...size.width)
                let y = CGFloat.random(in: 0...size.height)
                let radius = CGFloat.random(in: 20...80)
                
                context.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.2).cgColor)
                context.cgContext.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
        }
        
        if prompt.contains("square") || prompt.contains("box") {
            for _ in 0..<2 {
                let x = CGFloat.random(in: 0...size.width - 100)
                let y = CGFloat.random(in: 0...size.height - 100)
                let side = CGFloat.random(in: 50...100)
                
                context.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.15).cgColor)
                context.cgContext.fill(CGRect(x: x, y: y, width: side, height: side))
            }
        }
    }
    
    private func addPatterns(context: UIGraphicsImageRendererContext, prompt: String, size: CGSize) {
        // Add line patterns
        if prompt.contains("line") || prompt.contains("stripe") {
            context.cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.3).cgColor)
            context.cgContext.setLineWidth(2)
            
            for i in stride(from: 0, to: size.height, by: 20) {
                context.cgContext.move(to: CGPoint(x: 0, y: i))
                context.cgContext.addLine(to: CGPoint(x: size.width, y: i))
            }
            context.cgContext.strokePath()
        }
    }
    
    private func addSpecialEffects(context: UIGraphicsImageRendererContext, prompt: String, size: CGSize) {
        // Add sparkles for magical/beautiful prompts
        if prompt.contains("magic") || prompt.contains("beautiful") || prompt.contains("sparkle") || prompt.contains("star") {
            for _ in 0..<20 {
                let x = CGFloat.random(in: 0...size.width)
                let y = CGFloat.random(in: 0...size.height)
                let radius = CGFloat.random(in: 1...4)
                
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fillEllipse(in: CGRect(x: x - radius/2, y: y - radius/2, width: radius, height: radius))
            }
        }
        
        // Add dots for abstract patterns
        if prompt.contains("abstract") || prompt.contains("pattern") {
            for _ in 0..<50 {
                let x = CGFloat.random(in: 0...size.width)
                let y = CGFloat.random(in: 0...size.height)
                let radius = CGFloat.random(in: 1...3)
                
                context.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.4).cgColor)
                context.cgContext.fillEllipse(in: CGRect(x: x - radius/2, y: y - radius/2, width: radius, height: radius))
            }
        }
    }
    
    private func processDrawing(_ drawing: UIImage) -> UIImage {
        // Simple image processing to enhance the drawing
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            // White background
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            
            // Draw the original drawing scaled to fit
            let aspectRatio = drawing.size.width / drawing.size.height
            let targetSize: CGSize
            
            if aspectRatio > 1 {
                targetSize = CGSize(width: size.width, height: size.width / aspectRatio)
            } else {
                targetSize = CGSize(width: size.height * aspectRatio, height: size.height)
            }
            
            let targetRect = CGRect(
                x: (size.width - targetSize.width) / 2,
                y: (size.height - targetSize.height) / 2,
                width: targetSize.width,
                height: targetSize.height
            )
            
            drawing.draw(in: targetRect)
        }
    }
    
    private func createRealisticImage(for prompt: String) -> UIImage {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            // Create a more sophisticated background based on prompt keywords
            let colors = generateColorsFromPrompt(prompt)
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
            
            context.cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
            
            // Add some visual elements based on prompt
            addVisualElements(context: context, prompt: prompt, size: size)
            
            // Add a subtle watermark
            let watermark = "AI Generated"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.6)
            ]
            
            let textSize = watermark.size(withAttributes: attributes)
            let textRect = CGRect(
                x: size.width - textSize.width - 16,
                y: size.height - textSize.height - 16,
                width: textSize.width,
                height: textSize.height
            )
            
            watermark.draw(in: textRect, withAttributes: attributes)
        }
    }
    
    private func generateColorsFromPrompt(_ prompt: String) -> [CGColor] {
        let lowercased = prompt.lowercased()
        
        if lowercased.contains("sunset") || lowercased.contains("sunrise") {
            return [UIColor.systemOrange.cgColor, UIColor.systemPink.cgColor, UIColor.systemPurple.cgColor]
        } else if lowercased.contains("ocean") || lowercased.contains("sea") || lowercased.contains("water") {
            return [UIColor.systemBlue.cgColor, UIColor.systemCyan.cgColor, UIColor.systemTeal.cgColor]
        } else if lowercased.contains("forest") || lowercased.contains("tree") || lowercased.contains("nature") {
            return [UIColor.systemGreen.cgColor, UIColor.systemMint.cgColor, UIColor.systemTeal.cgColor]
        } else if lowercased.contains("fire") || lowercased.contains("flame") || lowercased.contains("red") {
            return [UIColor.systemRed.cgColor, UIColor.systemOrange.cgColor, UIColor.systemYellow.cgColor]
        } else if lowercased.contains("space") || lowercased.contains("galaxy") || lowercased.contains("star") {
            return [UIColor.black.cgColor, UIColor.systemPurple.cgColor, UIColor.systemBlue.cgColor]
        } else {
            return [UIColor.systemBlue.cgColor, UIColor.systemPurple.cgColor, UIColor.systemPink.cgColor]
        }
    }
    
    private func addVisualElements(context: UIGraphicsImageRendererContext, prompt: String, size: CGSize) {
        let lowercased = prompt.lowercased()
        
        // Add some geometric shapes based on prompt
        if lowercased.contains("circle") || lowercased.contains("round") {
            context.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.3).cgColor)
            context.cgContext.fillEllipse(in: CGRect(x: size.width/2 - 50, y: size.height/2 - 50, width: 100, height: 100))
        } else if lowercased.contains("square") || lowercased.contains("box") {
            context.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.3).cgColor)
            context.cgContext.fill(CGRect(x: size.width/2 - 50, y: size.height/2 - 50, width: 100, height: 100))
        } else if lowercased.contains("triangle") {
            context.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.3).cgColor)
            context.cgContext.move(to: CGPoint(x: size.width/2, y: size.height/2 - 50))
            context.cgContext.addLine(to: CGPoint(x: size.width/2 - 50, y: size.height/2 + 50))
            context.cgContext.addLine(to: CGPoint(x: size.width/2 + 50, y: size.height/2 + 50))
            context.cgContext.closePath()
            context.cgContext.fillPath()
        }
        
        // Add some sparkles for magical/beautiful prompts
        if lowercased.contains("magic") || lowercased.contains("beautiful") || lowercased.contains("sparkle") {
            for _ in 0..<10 {
                let x = CGFloat.random(in: 0...size.width)
                let y = CGFloat.random(in: 0...size.height)
                let radius = CGFloat.random(in: 2...6)
                
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fillEllipse(in: CGRect(x: x - radius/2, y: y - radius/2, width: radius, height: radius))
            }
        }
    }
    
    private func createPlaceholderImage(for prompt: String) -> UIImage {
        return createRealisticImage(for: prompt)
    }

    private static func resizeUIImage(_ image: UIImage, to size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // Simple bicubic 2× upscaler using Core Image
    private func simpleUpscale(image: UIImage, scale: CGFloat) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return nil }
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaled = ciImage.transformed(by: transform)
        guard let cg = context.createCGImage(scaled, from: CGRect(origin: .zero, size: targetSize)) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Model Storage
class ModelStorage {
    static let shared = ModelStorage()
    
    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    private let modelsDirectory: URL
    private let activeModelKey = "active_sd_model_id"
    
    private init() {
        modelsDirectory = documentsDirectory.appendingPathComponent("StableDiffusionModels")
        createModelsDirectoryIfNeeded()
    }
    
    private func createModelsDirectoryIfNeeded() {
        if !FileManager.default.fileExists(atPath: modelsDirectory.path) {
            try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        }
    }

    // Lightweight validation for installed content
    fileprivate func directoryLooksInstalled(_ root: URL) -> Bool {
        let fm = FileManager.default
        let compiled = root.appendingPathComponent("compiled")
        if fm.fileExists(atPath: compiled.path) { return true }
        if let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for item in items {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue, item.pathExtension == "mlmodelc" {
                    return true
                }
            }
        }
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let item as URL in en {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                    if item.lastPathComponent.lowercased() == "compiled" { return true }
                    if item.pathExtension == "mlmodelc" { return true }
                }
            }
        }
        return false
    }
    
    func getDownloadedModels() -> [StableDiffusionModel] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var models: [StableDiffusionModel] = []
        for url in contents {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                // Consider a directory a valid model if it contains any .mlmodelc folder or compiled resources
                if containsCompiledResources(at: url) && hasVAEComponent(at: url) {
                    let id = url.lastPathComponent
                    // Hide legacy built-in folder from UI
                    if id == "stable-diffusion-coreml" { continue }
                    let friendly = id.replacingOccurrences(of: "-", with: " ")
                    models.append(StableDiffusionModel(
                        id: id,
                        name: friendly.capitalized,
                        description: "Installed CoreML Stable Diffusion resources",
                        size: "—",
                        downloadUrl: ""
                    ))
                }
            }
        }
        return models.sorted { $0.name < $1.name }
    }

    // Detect if a directory contains compiled CoreML resources for Stable Diffusion
    private func containsCompiledResources(at root: URL) -> Bool {
        let fm = FileManager.default
        // Quick checks: any direct .mlmodelc or compiled subdir folders
        if let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for item in items {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                    if item.pathExtension == "mlmodelc" { return true }
                    if item.lastPathComponent.lowercased().contains("compiled") { return true }
                }
                if item.lastPathComponent.lowercased() == "merges.txt" { return true }
            }
        }
        // Deep check for .mlmodelc folder anywhere inside
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue, url.pathExtension == "mlmodelc" {
                return true
            }
        }
        return false
    }

    // Heuristic: consider model valid only if a VAE/Autoencoder component is present
    private func hasVAEComponent(at root: URL) -> Bool {
        let fm = FileManager.default
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                let name = url.lastPathComponent.lowercased()
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue, url.pathExtension == "mlmodelc" {
                    if name.contains("vae") || name.contains("autoencoder") { return true }
                }
            }
        }
        return false
    }

    func getActiveModelId() -> String? {
        UserDefaults.standard.string(forKey: activeModelKey)
    }

    func setActiveModelId(_ id: String) {
        UserDefaults.standard.set(id, forKey: activeModelKey)
    }

    func getActiveModelResourcesURL() -> URL? {
        let fm = FileManager.default
        func preferCompiled(at base: URL) -> URL? {
            // Prefer compiled/ subfolder when present, otherwise return a directory that contains
            // all required resources (never an individual .mlmodelc bundle)
            let compiled = base.appendingPathComponent("compiled")
            if fm.fileExists(atPath: compiled.path) { return compiled }
            // If base has merges.txt, return base
            if fm.fileExists(atPath: base.appendingPathComponent("merges.txt").path) { return base }
            // Search one level deep for a child that contains compiled/ or merges.txt; return that directory (not an .mlmodelc)
            if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for item in items {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                        let subCompiled = item.appendingPathComponent("compiled")
                        if fm.fileExists(atPath: subCompiled.path) { return subCompiled }
                        if fm.fileExists(atPath: item.appendingPathComponent("merges.txt").path) { return item }
                        // If child contains any .mlmodelc, prefer the child directory (not the .mlmodelc itself)
                        if let grandchildren = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                            for gc in grandchildren {
                                var isDir2: ObjCBool = false
                                if fm.fileExists(atPath: gc.path, isDirectory: &isDir2), isDir2.boolValue, gc.pathExtension == "mlmodelc" {
                                    return item
                                }
                            }
                        }
                    }
                }
            }
            // As a last resort, if base directly contains .mlmodelc(s), return base
            if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for item in items {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue, item.pathExtension == "mlmodelc" {
                        return base
                    }
                }
            }
            return base
        }
        if let chosen = getActiveModelId(), !chosen.isEmpty {
            let base = modelsDirectory.appendingPathComponent(chosen)
            if fm.fileExists(atPath: base.path) { return preferCompiled(at: base) }
        }
        let legacy = modelsDirectory.appendingPathComponent("stable-diffusion-coreml")
        if fm.fileExists(atPath: legacy.path) { return preferCompiled(at: legacy) }
        return nil
    }
    
    func downloadModel(_ model: StableDiffusionModel, progress: @escaping (Double) -> Void) async throws {
        print("📥 Starting download for model: \(model.name)")

        // For CoreML models, we need to download the actual model files
        if model.id.hasPrefix("http") || model.downloadUrl.hasPrefix("http") || model.id == "stable-diffusion-coreml" {
            let destRoot = modelsDirectory.appendingPathComponent(model.id)
            try? FileManager.default.removeItem(at: destRoot)
            try? FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
            try await downloadCoreMLModel(from: model.downloadUrl, modelId: model.id, destRootOverride: destRoot, progress: progress)
        } else {
            try await simulateDownload(model: model, progress: progress)
        }

        print("✅ Download completed for model: \(model.name)")
        // Make newly downloaded model active if no active set
        if getActiveModelId() == nil { setActiveModelId(model.id) }
    }
    
    // MARK: Real streaming download + unzip to Documents
    private func downloadCoreMLModel(from repositoryURL: String, modelId: String, destRootOverride: URL?, progress: @escaping (Double) -> Void) async throws {
        // Expecting a direct link to a zip containing the compiled .mlmodelc
        // Example: https://huggingface.co/apple/coreml-stable-diffusion-v1-4/resolve/main/StableDiffusion.mlmodelc.zip
        let trimmed = repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".zip") || trimmed.contains("drive.google.com") {
            // Handle Google Drive links by following redirects to content download
            let effectiveURL: URL
            if trimmed.contains("drive.google.com") {
                // Convert viewing URL to direct download if possible
                if let idRange = trimmed.range(of: "/d/")?.upperBound,
                   let end = trimmed[idRange...].firstIndex(of: "/") {
                    let fileId = String(trimmed[idRange..<end])
                    effectiveURL = URL(string: "https://drive.google.com/uc?export=download&id=\(fileId)&confirm=t")!
                } else if let url = URL(string: trimmed) {
                    effectiveURL = url
                } else {
                    throw StableDiffusionError.generationFailed
                }
            } else {
                guard let url = URL(string: trimmed) else { throw StableDiffusionError.generationFailed }
                effectiveURL = url
            }
            let zipURL = effectiveURL
            let destRoot: URL
            if let override = destRootOverride { destRoot = override } else { destRoot = try resolveModelDirectoryFor(downloadUrl: repositoryURL) }
            try await downloadAndUnzipZip(at: zipURL, modelId: modelId, destRoot: destRoot, progress: progress)
            return
        }
        if trimmed.hasSuffix(".mlmodel") {
            guard let mlmodelURL = URL(string: trimmed) else { throw StableDiffusionError.generationFailed }
            let destRoot: URL
            if let override = destRootOverride { destRoot = override } else { destRoot = try resolveModelDirectoryFor(downloadUrl: repositoryURL) }
            try await downloadAndCompileMLModel(at: mlmodelURL, modelId: modelId, destRoot: destRoot, progress: progress)
            return
        }
        // If this looks like a Hugging Face repo, attempt multi-file download of split_einsum/compiled
        if trimmed.contains("huggingface.co/") || !trimmed.contains("http") {
            let repoId: String
            if let range = trimmed.range(of: "huggingface.co/") {
                repoId = String(trimmed[range.upperBound...])
            } else {
                repoId = trimmed
            }
            let destRoot: URL
            if let override = destRootOverride { destRoot = override } else { destRoot = try resolveModelDirectoryFor(downloadUrl: repositoryURL) }
            // Choose subdir depending on org/repo pattern
            let subdir: String
            if repoId.hasPrefix("coreml-community/") {
                subdir = "split_einsum/compiled"
            } else {
                subdir = "compiled"
            }
            try await downloadHuggingFaceCompiled(repoId: repoId, subdir: subdir, modelId: modelId, destRoot: destRoot, progress: progress)
            return
        }
        throw StableDiffusionError.generationFailed
    }

    private func resolveModelDirectoryFor(downloadUrl: String) throws -> URL {
        let id: String
        if downloadUrl.contains("huggingface.co") {
            // Use repo name as id
            let comps = downloadUrl.split(separator: "/").map(String.init)
            if let idx = comps.firstIndex(of: "coreml-community") ?? comps.firstIndex(of: "apple"), idx + 1 < comps.count {
                id = comps[idx + 1]
            } else if let last = comps.drop(while: { !$0.contains("coreml") && !$0.contains("epicrealism") }).last {
                id = last
            } else {
                id = "stable-diffusion-coreml"
            }
        } else if let url = URL(string: downloadUrl) {
            id = url.deletingPathExtension().lastPathComponent
        } else {
            id = downloadUrl.replacingOccurrences(of: "/", with: "-")
        }
        return modelsDirectory.appendingPathComponent(id)
    }

    // MARK: - Hugging Face multi-file download for compiled assets (robust)
    private func downloadHuggingFaceCompiled(repoId: String, subdir: String, modelId: String, destRoot: URL, progress: @escaping (Double) -> Void) async throws {
        // Prefer tree API for full recursive listing; fallback to siblings API
        let treeURL = URL(string: "https://huggingface.co/api/models/\(repoId)/tree/main?recursive=1")!
        struct HFEntry { let path: String; let isFile: Bool }
        var allEntries: [HFEntry] = []
        do {
            let (treeData, treeResp) = try await URLSession.shared.data(from: treeURL)
            if let treeHttp = treeResp as? HTTPURLResponse, (200...299).contains(treeHttp.statusCode) {
                let entries = (try? JSONSerialization.jsonObject(with: treeData) as? [[String: Any]]) ?? []
                allEntries = entries.compactMap { dict in
                    guard let path = dict["path"] as? String else { return nil }
                    let type = (dict["type"] as? String) ?? "file"
                    return HFEntry(path: path, isFile: type == "file")
                }
            }
        } catch {
            // Ignore and try siblings API
        }
        if allEntries.isEmpty {
            let api = URL(string: "https://huggingface.co/api/models/\(repoId)")!
            let (data, response) = try await URLSession.shared.data(from: api)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw StableDiffusionError.generationFailed }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let siblings = json["siblings"] as? [[String: Any]] {
                let paths = siblings.compactMap { $0["rfilename"] as? String }
                allEntries = paths.map { HFEntry(path: $0, isFile: true) }
            }
        }

        // Choose ONE compiled subtree to avoid filename collisions (e.g., SafetyChecker.mlmodelc in both trees)
        let preferredOrder = [
            "split_einsum/compiled/",
            "original/compiled/",
            (subdir.hasSuffix("/") ? subdir : subdir + "/"),
            "compiled/"
        ]
        var chosenPrefix: String? = nil
        for cand in preferredOrder {
            if allEntries.contains(where: { $0.path.hasPrefix(cand) }) { chosenPrefix = cand; break }
        }
        // If nothing matched, keep any path that contains compiled/ to try best-effort
        var files: [String]
        if let chosen = chosenPrefix {
            files = allEntries.filter { $0.isFile && $0.path.hasPrefix(chosen) }.map { $0.path }
        } else {
            files = allEntries.filter { $0.isFile && $0.path.contains("compiled/") }.map { $0.path }
        }
        // Make unique and sort
        files = Array(Set(files)).sorted()

        // Fallback to any zip under split_einsum or compiled
        if files.isEmpty {
            let allPathsList = allEntries.map { $0.path }
            if let zipPath = allPathsList.first(where: { ($0.contains("split_einsum/") || $0.contains("compiled")) && $0.lowercased().hasSuffix(".zip") }) {
                let resolveURL = URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(zipPath)")!
                try await downloadAndUnzipZip(at: resolveURL, modelId: modelId, destRoot: destRoot, progress: progress)
                return
            }
        }
        guard files.isEmpty == false else { throw StableDiffusionError.generationFailed }

        // Clean destination
        let parent = destRoot.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destRoot)
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)

        // Download each file, normalize relative path to start after the first occurrence of "compiled/"
        for (idx, path) in files.enumerated() {
            let relative: String = {
                if let chosen = chosenPrefix, let r = path.range(of: chosen) {
                    return String(path[r.upperBound...])
                }
                if let range = path.range(of: "compiled/") { return String(path[range.upperBound...]) }
                return (path as NSString).lastPathComponent
            }()
            let resolveURL = URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(path)")!
            let targetURL = destRoot.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = try await downloadFileWithProgress(from: resolveURL, progress: { perFile in
                let fileWeight = 1.0 / Double(files.count)
                let completed = Double(idx) / Double(files.count)
                progress(min(1.0, completed + perFile * fileWeight))
            }, bytesProgress: { written, expected in
                NotificationCenter.default.post(name: StableDiffusionService.bytesNotification, object: nil, userInfo: ["modelId": modelId, "written": written, "expected": expected])
            })
            if FileManager.default.fileExists(atPath: targetURL.path) {
                // Try replace atomically to avoid Code=516
                do {
                    _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: temp)
                } catch {
                    // As a fallback, remove and move; if still fails, write with a unique suffix
                    try? FileManager.default.removeItem(at: targetURL)
                    do { try FileManager.default.moveItem(at: temp, to: targetURL) }
                    catch {
                        let unique = targetURL.deletingPathExtension().appendingPathExtension("dup_\(UUID().uuidString)").appendingPathExtension(targetURL.pathExtension)
                        try? FileManager.default.moveItem(at: temp, to: unique)
                    }
                }
            } else {
                try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try FileManager.default.moveItem(at: temp, to: targetURL) } catch { try FileManager.default.copyItem(at: temp, to: targetURL) }
            }
        }
        progress(1.0)
        NotificationCenter.default.post(name: NSNotification.Name("ModelDownloaded"), object: nil)
    }

    private func downloadAndUnzipZip(at zipURL: URL, modelId: String, destRoot: URL, progress: @escaping (Double) -> Void) async throws {
        let baseDir = destRoot.deletingLastPathComponent()
        let zipDestinationURL = baseDir.appendingPathComponent("StableDiffusion_download_\(UUID().uuidString).zip")
        let tempExtractURL = baseDir.appendingPathComponent("StableDiffusion_tmp_extract_\(UUID().uuidString)")

        // Ensure base directory exists
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: zipDestinationURL)
        try? FileManager.default.removeItem(at: destRoot)

        let downloadedTempURL = try await downloadFileWithProgress(from: zipURL, progress: progress, bytesProgress: { written, expected in
            NotificationCenter.default.post(name: StableDiffusionService.bytesNotification, object: nil, userInfo: ["modelId": modelId, "written": written, "expected": expected])
        })
        // Verify temp exists; if not, throw early
        guard FileManager.default.fileExists(atPath: downloadedTempURL.path) else {
            throw StableDiffusionError.generationFailed
        }
        do {
            try FileManager.default.moveItem(at: downloadedTempURL, to: zipDestinationURL)
        } catch {
            // Fallback to copy in case the temp file is transiently removed by the system
            try FileManager.default.copyItem(at: downloadedTempURL, to: zipDestinationURL)
        }

        try FileManager.default.createDirectory(at: tempExtractURL, withIntermediateDirectories: true)
        // Validate downloaded file looks like a zip (basic check)
        let attr = try FileManager.default.attributesOfItem(atPath: zipDestinationURL.path)
        if let size = attr[.size] as? NSNumber, size.intValue < 1024 * 100 {
            // Too small likely an HTML page or quota page
            try? FileManager.default.removeItem(at: zipDestinationURL)
            try? FileManager.default.removeItem(at: tempExtractURL)
            throw StableDiffusionError.generationFailed
        }
        NotificationCenter.default.post(name: StableDiffusionService.unzipStartedNotification, object: nil, userInfo: ["modelId": modelId])
        // Unzip with progress
        try unzipWithProgress(zipURL: zipDestinationURL, to: tempExtractURL, modelId: modelId)

        // Determine best install source from extracted contents
        let fm = FileManager.default
        func topLevelRoot(_ url: URL) -> URL {
            // If archive produced a single folder, use it as root; else use extraction root
            if let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]), items.count == 1 {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: items[0].path, isDirectory: &isDir), isDir.boolValue { return items[0] }
            }
            return url
        }
        // Descend through single-folder nesting to reach payload
        func descendToPayload(_ url: URL) -> URL {
            let fm = FileManager.default
            var current = url
            while true {
                guard let items = try? fm.contentsOfDirectory(at: current, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { break }
                // Filter out __MACOSX and hidden
                let dirs = items.filter { u in
                    var isDir: ObjCBool = false
                    return fm.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue && u.lastPathComponent != "__MACOSX"
                }
                if dirs.count == 1 { current = dirs[0] } else { break }
            }
            return current
        }
        let root = descendToPayload(topLevelRoot(tempExtractURL))

        // Prefer a compiled directory anywhere inside
        func findCompiledDir(at url: URL) -> URL? {
            if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for case let item as URL in enumerator {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue, item.lastPathComponent.lowercased() == "compiled" {
                        return item
                    }
                }
            }
            return nil
        }

        let compiledDir = findCompiledDir(at: root)
        let firstBundle = try findFirstMLModelCDirectory(at: root)

        // Clean destination
        try? fm.removeItem(at: destRoot)
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

        var installedSomething = false
        if let compiled = compiledDir {
            // Move compiled directory under destRoot/compiled (overwrite if exists)
            let target = destRoot.appendingPathComponent("compiled")
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            // Prefer copy to avoid any subsequent deletion by cleanup
            do { try fm.copyItem(at: compiled, to: target) } catch {
                try? fm.removeItem(at: target)
                try fm.copyItem(at: compiled, to: target)
            }
            installedSomething = true
        } else if let bundle = firstBundle {
            // Move the parent folder of the bundle to preserve related resources (tokenizers, etc.) if possible
            let parent = bundle.deletingLastPathComponent()
            if parent != root {
                let target = destRoot.appendingPathComponent(parent.lastPathComponent)
                if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
                do { try fm.copyItem(at: parent, to: target) } catch {
                    try? fm.removeItem(at: target)
                    try fm.copyItem(at: parent, to: target)
                }
                installedSomething = true
            } else {
                // Move the bundle itself
                let target = destRoot.appendingPathComponent(bundle.lastPathComponent)
                if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
                do { try fm.copyItem(at: bundle, to: target) } catch {
                    try? fm.removeItem(at: target)
                    try fm.copyItem(at: bundle, to: target)
                }
                installedSomething = true
            }
        } else {
            // Fallback: move all extracted contents into destRoot
            if let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for item in items {
                    let target = destRoot.appendingPathComponent(item.lastPathComponent)
                    if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
                    do { try fm.copyItem(at: item, to: target) } catch { /* ignore */ }
                }
                installedSomething = true
            }
        }

        // Final verification; if not looking installed, try copying everything from the extraction root
        if !ModelStorage.shared.directoryLooksInstalled(destRoot) || installedSomething == false {
            if let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for item in items {
                    let target = destRoot.appendingPathComponent(item.lastPathComponent)
                    if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
                    do { try fm.copyItem(at: item, to: target) } catch { /* ignore and continue */ }
                }
            }
        }

        try? FileManager.default.removeItem(at: zipDestinationURL)
        try? FileManager.default.removeItem(at: tempExtractURL)

        NotificationCenter.default.post(name: StableDiffusionService.unzipFinishedNotification, object: nil, userInfo: ["modelId": modelId])
        NotificationCenter.default.post(name: NSNotification.Name("ModelDownloaded"), object: nil)
    }

    // MARK: - ZIP extraction with progress
    private func unzipWithProgress(zipURL: URL, to destination: URL, modelId: String) throws {
        guard let archive = Archive(url: zipURL, accessMode: .read) else {
            throw StableDiffusionError.generationFailed
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let entries = Array(archive)
        let total = entries.count
        var index = 0
        for entry in entries {
            let destPath = destination.appendingPathComponent(entry.path)
            try fm.createDirectory(at: destPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: destPath)
            index += 1
            let frac = min(1.0, max(0.0, Double(index) / Double(max(1, total))))
            NotificationCenter.default.post(name: StableDiffusionService.unzipProgressNotification, object: nil, userInfo: ["modelId": modelId, "progress": frac])
        }
    }

    private func downloadAndCompileMLModel(at mlmodelURL: URL, modelId: String, destRoot: URL, progress: @escaping (Double) -> Void) async throws {
        let mlmodelDestinationURL = destRoot.appendingPathComponent("StableDiffusion.mlmodel")
        let compiledDestinationURL = destRoot.appendingPathComponent("StableDiffusion.mlmodelc")

        try? FileManager.default.removeItem(at: mlmodelDestinationURL)
        try? FileManager.default.removeItem(at: compiledDestinationURL)

        let downloadedTempURL = try await downloadFileWithProgress(from: mlmodelURL, progress: progress, bytesProgress: { written, expected in
            NotificationCenter.default.post(name: StableDiffusionService.bytesNotification, object: nil, userInfo: ["modelId": modelId, "written": written, "expected": expected])
        })
        try FileManager.default.moveItem(at: downloadedTempURL, to: mlmodelDestinationURL)

        // Compile on-device to .mlmodelc
        let compiledURL = try await MLModel.compileModel(at: mlmodelDestinationURL)
        // Ensure compiled bundle resides under destRoot preserving .mlmodelc bundle
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: compiledURL, to: compiledDestinationURL)

        NotificationCenter.default.post(name: NSNotification.Name("ModelDownloaded"), object: nil)
    }

    // MARK: URLSession streamed download with progress
    private func downloadFileWithProgress(from url: URL, progress: @escaping (Double) -> Void, bytesProgress: ((Int64, Int64) -> Void)? = nil) async throws -> URL {
        class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
            let onProgress: (Double) -> Void
            let onBytes: ((Int64, Int64) -> Void)?
            var continuation: CheckedContinuation<URL, Error>?
            init(onProgress: @escaping (Double) -> Void, onBytes: ((Int64, Int64) -> Void)?) { self.onProgress = onProgress; self.onBytes = onBytes }
            func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
                // Immediately move/copy to our own temp to avoid CFNetwork cleanup races
                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                let target = tempDir.appendingPathComponent("sd_dl_\(UUID().uuidString)")
                do { try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true) } catch {}
                do {
                    try FileManager.default.copyItem(at: location, to: target)
                    continuation?.resume(returning: target)
                } catch {
                    do {
                        try FileManager.default.moveItem(at: location, to: target)
                        continuation?.resume(returning: target)
                    } catch {
                        continuation?.resume(throwing: error)
                    }
                }
            }
            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                if let error = error { continuation?.resume(throwing: error) }
            }
            func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
                guard totalBytesExpectedToWrite > 0 else { return }
                onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
                onBytes?(totalBytesWritten, totalBytesExpectedToWrite)
            }
        }

        let delegate = DownloadDelegate(onProgress: progress, onBytes: bytesProgress)
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.addValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        progress(0.0)
        task.resume()
        let location = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            delegate.continuation = continuation
        }
        progress(1.0)
        return location
    }

    // Recursively find first directory with .mlmodelc extension
    private func findFirstMLModelCDirectory(at root: URL) throws -> URL? {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        while let item = enumerator?.nextObject() as? URL {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue, item.pathExtension == "mlmodelc" {
                return item
            }
        }
        return nil
    }
    
    private func simulateDownload(model: StableDiffusionModel, progress: @escaping (Double) -> Void) async throws {
        // Simulate realistic download progress based on model size
        let modelSizeGB = Double(model.size.replacingOccurrences(of: " GB", with: "")) ?? 2.0
        let totalSteps = Int(modelSizeGB * 50) // More steps for larger models
        
        for i in 0...totalSteps {
            // Simulate realistic download speed (slower for larger models)
            let baseDelay: UInt64 = UInt64(100_000_000 * modelSizeGB) // 100ms * model size
            let progressFactor = Double(i) / Double(totalSteps)
            let delay = baseDelay + UInt64(progressFactor * 200_000_000) // 100-300ms
            
            try await Task.sleep(nanoseconds: delay)
            
            // Add some randomness to make it feel more realistic
            let randomVariation = Double.random(in: 0.9...1.1)
            let adjustedProgress = min(Double(i) / Double(totalSteps) * randomVariation, 1.0)
            progress(adjustedProgress)
            
            // Simulate occasional pauses (like real downloads)
            if i % 15 == 0 && i > 0 {
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms pause
            }
        }
    }
    
    func deleteModel(_ model: StableDiffusionModel) async throws {
        let modelPath = modelsDirectory.appendingPathComponent(model.id)
        try FileManager.default.removeItem(at: modelPath)
    }

    // MARK: - Import model from Files (zip / mlmodel / mlmodelc / folder)
    func importModel(from pickedURL: URL) async throws -> StableDiffusionModel {
        let fm = FileManager.default
        let access = pickedURL.startAccessingSecurityScopedResource()
        defer { if access { pickedURL.stopAccessingSecurityScopedResource() } }

        let ext = pickedURL.pathExtension.lowercased()
        // Determine destination root by name
        let baseName = pickedURL.deletingPathExtension().lastPathComponent
        let destRoot = modelsDirectory.appendingPathComponent(baseName)
        try? fm.removeItem(at: destRoot)
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

        if ext == "zip" {
            // Reuse unzip helper
            try await downloadAndUnzipZip(at: pickedURL, modelId: baseName, destRoot: destRoot, progress: { _ in })
        } else if ext == "mlmodel" {
            try await downloadAndCompileMLModel(at: pickedURL, modelId: baseName, destRoot: destRoot, progress: { _ in })
        } else if ext == "mlmodelc" {
            // Copy compiled bundle into destination root, preserving bundle name
            try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
            let target = destRoot.appendingPathComponent(pickedURL.lastPathComponent)
            try? fm.removeItem(at: target)
            do { try fm.copyItem(at: pickedURL, to: target) } catch { try fm.moveItem(at: pickedURL, to: target) }
        } else {
            // If it's a directory, copy as-is if it contains compiled resources
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: pickedURL.path, isDirectory: &isDir), isDir.boolValue {
                if containsCompiledResources(at: pickedURL) {
                    try? fm.removeItem(at: destRoot)
                    try fm.copyItem(at: pickedURL, to: destRoot)
                } else {
                    throw StableDiffusionError.generationFailed
                }
            } else {
                // Unknown type
                throw StableDiffusionError.generationFailed
            }
        }

        NotificationCenter.default.post(name: NSNotification.Name("ModelDownloaded"), object: nil)
        return StableDiffusionModel(id: baseName, name: baseName.replacingOccurrences(of: "-", with: " ").capitalized, description: "Imported model", size: "—", downloadUrl: "")
    }
}

