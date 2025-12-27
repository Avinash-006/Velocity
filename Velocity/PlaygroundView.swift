import SwiftUI
import PencilKit
import PhotosUI

struct PlaygroundView: View {
    @State private var canvasView = PKCanvasView()
    @State private var isGenerating = false
    @State private var generatedImage: UIImage?
    @State private var showingImagePreview = false
    @State private var modelAvailable = false
    @State private var previewFrames: [UIImage] = []
    @State private var stepCount: Double = 25
    @State private var guidance: Double = 7.5
    @State private var persistedThumbnails: [UIImage] = []
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Playground")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button(action: clearCanvas) {
                    Image(systemName: "trash")
                        .font(.title2)
                        .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            // Drawing Canvas
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                    )
                
                DrawingCanvasView(canvasView: $canvasView)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            .padding(.horizontal, 20)
            .frame(maxHeight: .infinity)
            
            // Generate Button
            VStack(spacing: 16) {
                if !persistedThumbnails.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(persistedThumbnails.enumerated()), id: \.offset) { _, img in
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 70, height: 70)
                                    .clipped()
                                    .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                // Settings
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Steps: \(Int(stepCount))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(value: $stepCount, in: 5...50, step: 1)
                    }
                    HStack {
                        Text("Guidance: \(String(format: "%.1f", guidance))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(value: $guidance, in: 1.0...12.0, step: 0.5)
                    }
                }
                .disabled(!modelAvailable)

                // Live preview frames
                if !previewFrames.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(previewFrames.enumerated()), id: \.offset) { _, img in
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 90, height: 90)
                                    .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                if generatedImage != nil {
                    Button(action: { showingImagePreview = true }) {
                        HStack {
                            Image(systemName: "photo")
                            Text("View Generated Image")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(.mint)
                        .cornerRadius(25)
                    }
                }
                
                if !modelAvailable {
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text("Model Required")
                                .font(.headline)
                                .foregroundColor(.orange)
                        }
                        
                        Text("Download the Stable Diffusion model from the Model Management tab to generate images.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .background(.orange.opacity(0.1))
                    .cornerRadius(12)
                }
                
                Button(action: generateImage) {
                    HStack {
                        if isGenerating {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text(isGenerating ? "Generating..." : "Generate Image")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(isGenerating ? .gray : (modelAvailable ? .mint : .gray))
                    .cornerRadius(25)
                }
                .disabled(isGenerating || canvasView.drawing.strokes.isEmpty || !modelAvailable)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(.regularMaterial)
        .sheet(isPresented: $showingImagePreview) {
            if let image = generatedImage {
                ImagePreviewView(image: image)
            }
        }
        .onAppear {
            checkModelAvailability()
            subscribeProgress()
            loadPersistedThumbnails()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            checkModelAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ModelDownloaded"))) { _ in
            checkModelAvailability()
        }
    }
    
    private func clearCanvas() {
        canvasView.drawing = PKDrawing()
    }
    
    private func checkModelAvailability() {
        modelAvailable = ModelStorage.shared.getActiveModelResourcesURL() != nil
    }
    
    private func generateImage() {
        guard !canvasView.drawing.strokes.isEmpty else { return }
        
        isGenerating = true
        previewFrames.removeAll()
        
        // Convert drawing to image with a safe fallback rect
        let bounds = canvasView.bounds
        let captureRect: CGRect
        if bounds.width >= 2 && bounds.height >= 2 {
            captureRect = bounds
        } else {
            captureRect = CGRect(x: 0, y: 0, width: 512, height: 512)
        }
        let image = canvasView.drawing.image(from: captureRect, scale: 1.0)
        
        Task {
            do {
                let settings = StableDiffusionService.GenerationSettings(stepCount: Int(stepCount), guidanceScale: Float(guidance))
                _ = settings // reserved for future img2img settings
                let generatedImage = try await StableDiffusionService.shared.generateImage(from: image)
                await MainActor.run {
                    self.generatedImage = generatedImage
                    self.isGenerating = false
                    self.persist(image: generatedImage)
                }
            } catch {
                await MainActor.run {
                    self.isGenerating = false
                    if let stableDiffusionError = error as? StableDiffusionError,
                       case .modelNotFound = stableDiffusionError {
                        print("⚠️ Stable Diffusion model not found! Please download the model first.")
                    } else {
                        print("Error generating image: \(error)")
                    }
                }
            }
        }
    }

    private func subscribeProgress() {
        NotificationCenter.default.addObserver(forName: StableDiffusionService.progressNotification, object: nil, queue: .main) { note in
            if let img = note.userInfo?["image"] as? UIImage {
                // Keep last 10 frames to reduce memory
                previewFrames.append(img)
                if previewFrames.count > 10 { previewFrames.removeFirst(previewFrames.count - 10) }
            }
        }
    }
    
    // MARK: - Persistence helpers
    private func generatedDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Generated")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    private func persist(image: UIImage) {
        let dir = generatedDir()
        let name = "gen_\(Int(Date().timeIntervalSince1970)).jpg"
        let url = dir.appendingPathComponent(name)
        if let data = image.jpegData(compressionQuality: 0.9) {
            try? data.write(to: url)
        }
        // Maintain thumbnail cache (last 12)
        let thumb = imageThumbnail(image)
        persistedThumbnails.insert(thumb, at: 0)
        if persistedThumbnails.count > 12 { persistedThumbnails.removeLast(persistedThumbnails.count - 12) }
    }
    
    private func loadPersistedThumbnails() {
        let dir = generatedDir()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        let sorted = files.sorted { (a, b) -> Bool in
            let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return ad > bd
        }
        var thumbs: [UIImage] = []
        for url in sorted.prefix(12) {
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                thumbs.append(imageThumbnail(img))
            }
        }
        persistedThumbnails = thumbs
    }
    
    private func imageThumbnail(_ image: UIImage) -> UIImage {
        let size = CGSize(width: 100, height: 100)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

struct DrawingCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    
    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.drawingPolicy = .anyInput
        canvasView.backgroundColor = .clear
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 3)
        return canvasView
    }
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // Update if needed
    }
}

struct ImagePreviewView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false
    
    var body: some View {
        NavigationView {
            VStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(20)
                    .padding()
                    .contextMenu {
                        Button {
                            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        } label: {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            showShare = true
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                
                Spacer()
            }
            .navigationTitle("Generated Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(activityItems: [image])
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    PlaygroundView()
        .preferredColorScheme(.dark)
}
