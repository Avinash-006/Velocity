import SwiftUI
import UserNotifications

struct ImageLabView: View {
    @State private var prompt: String = ""
    @State private var negativePrompt: String = ""
    @State private var sampler: String = "default"
    @State private var imageCount: Int = 1
    @State private var steps: Double = 25
    @State private var guidance: Double = 7.5
    @State private var previewLatent: Bool = false
    @State private var previewDenoised: Bool = true
    @State private var isGenerating: Bool = false
    @State private var frames: [UIImage] = []
    @State private var currentStep: Int = 0
    @State private var finalImage: UIImage? = nil
    @State private var downloadedModels: [StableDiffusionModel] = []
    @State private var activeModelId: String? = ModelStorage.shared.getActiveModelId()
    @State private var modelAvailable: Bool = ModelStorage.shared.getActiveModelResourcesURL() != nil

    private let samplers: [String] = ["default", "euler_a", "euler", "ddim", "plms"]
    @State private var showingSamplerList: Bool = false
    @State private var reduceMemory: Bool = false
    @State private var selectedCompute: Int = 2 // 0: CPU+Neural, 1: CPU+GPU, 2: All
    // Upscaler selection sourced from Model Management (downloaded upscaler models)
    @State private var upscalers: [StableDiffusionModel] = []
    @State private var selectedUpscalerId: String = "none" // "none", "builtin_bicubic", or model.id
    @State private var seed: String = ""

    // Cache of computed on-disk sizes for grouping
    @State private var modelFolderSizes: [String: Int64] = [:] // model.id -> bytes
    
    // Notification settings
    @State private var notificationPermissionGranted: Bool = false
    @State private var enableNotifications: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            // Controls (Left)
            GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Image Lab")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    // Positive Prompt
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prompt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Describe your image...", text: $prompt, axis: .vertical)
                            .lineLimit(3...6)
                            .padding(10)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(12)
                    }

                    // Model selection (grouped by size)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("Model", selection: Binding(get: { activeModelId ?? "" }, set: { newVal in
                            activeModelId = newVal.isEmpty ? nil : newVal
                            if let id = activeModelId, !id.isEmpty { ModelStorage.shared.setActiveModelId(id) }
                            modelAvailable = ModelStorage.shared.getActiveModelResourcesURL() != nil
                        })) {
                            // Grouped sections by size category
                            let grouped = groupedModelsBySize()
                            ForEach(grouped.keys.sorted(by: sizeCategorySort), id: \.self) { category in
                                Section(header: Text(category)) {
                                    ForEach(grouped[category] ?? []) { model in
                                        Text(model.name).tag(model.id)
                                    }
                                }
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Negative Prompt
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Negative Prompt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("What to avoid...", text: $negativePrompt, axis: .vertical)
                            .lineLimit(2...5)
                            .padding(10)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(12)
                    }

                    // Compute Units
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Compute Units")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("Compute", selection: $selectedCompute) {
                            Text("CPU+Neural Engine").tag(0)
                            Text("CPU+GPU").tag(1)
                            Text("All").tag(2)
                        }
                        .pickerStyle(.segmented)
                    }

                    // Sampler and image count
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sampler")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button(action: { showingSamplerList = true }) {
                                HStack {
                                    Text(sampler)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                }
                                .padding(10)
                                .background(.ultraThinMaterial)
                                .cornerRadius(10)
                            }
                        }
                        VStack(alignment: .leading) {
                            Text("Images")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Stepper(value: $imageCount, in: 1...4) {
                                Text("\(imageCount)")
                            }
                        }
                    }

                    // Steps
                    VStack(alignment: .leading) {
                        Text("Steps: \(Int(steps))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(value: $steps, in: 5...75, step: 1)
                    }

                    // Guidance
                    VStack(alignment: .leading) {
                        Text(String(format: "Guidance: %.1f", guidance))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(value: $guidance, in: 1.0...15.0, step: 0.5)
                    }

                    // Seed
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Seed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            TextField("Random", text: $seed)
                                .keyboardType(.numberPad)
                                .padding(10)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(12)
                            Button("Random") {
                                seed = String(Int.random(in: 0...Int.max))
                            }
                            .font(.caption)
                            .foregroundColor(.mint)
                        }
                    }

                    // Upscaler picker (from Model Management)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Upscaler")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("Upscaler", selection: $selectedUpscalerId) {
                            Text("None").tag("none")
                            Text("2× Bicubic (Built‑in)").tag("builtin_bicubic")
                            ForEach(upscalers) { up in
                                Text(up.name).tag(up.id)
                            }
                        }
                        .pickerStyle(.menu)
                        Text("Tip: Upscalers come from Model Management (e.g., RealESRGAN).")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    // Preview toggles
                    Toggle("Preview Latent", isOn: $previewLatent)
                        .onChange(of: previewLatent) { newVal in
                            if newVal { previewDenoised = false }
                        }
                    Toggle("Preview Denoised", isOn: $previewDenoised)
                        .onChange(of: previewDenoised) { newVal in
                            if newVal { previewLatent = false }
                        }
                    Toggle("Reduce Memory Usage", isOn: $reduceMemory)
                    
                    // Notification toggle
                    Toggle("Enable Notifications", isOn: $enableNotifications)
                        .disabled(!notificationPermissionGranted)
                    
                    if !notificationPermissionGranted {
                        Text("Notification permissions not granted. Tap to request.")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .onTapGesture {
                                requestNotificationPermission()
                            }
                    }

                    // Generate Button
                    Button(action: generate) {
                        HStack {
                            if isGenerating { ProgressView().progressViewStyle(.circular) }
                            Text(isGenerating ? "Generating..." : "Generate Image")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(modelAvailable && !isGenerating && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.mint : Color.gray)
                        .cornerRadius(12)
                    }
                    .disabled(!modelAvailable || isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if !modelAvailable {
                        Text("No active model. Select or download one in Model Management.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity)
            .background(Color(UIColor.systemBackground))
            }

            Divider()

            // Preview (Right)
            ZStack {
                if let img = finalImage ?? frames.last {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.05))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("Generated image will appear here")
                            .foregroundColor(.secondary)
                    }
                }

                // Live step overlay and Save button (no thumbnail strip)
                if finalImage != nil || !frames.isEmpty {
                    VStack {
                        HStack(spacing: 10) {
                            Text("Live")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.8))
                                .cornerRadius(4)
                                .foregroundColor(.white)
                            Text("Step \(currentStep)")
                                .font(.caption)
                                .foregroundColor(.white)
                            Spacer()
                            Button {
                                if let img = finalImage ?? frames.last {
                                    UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                                }
                            } label: {
                                Label("Save", systemImage: "square.and.arrow.down")
                                    .font(.caption)
                                    .padding(6)
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(8)
                            }
                        }
                        Spacer()
                    }
                    .padding(10)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            reloadModels()
            subscribeProgress()
            checkNotificationPermission()
            // First launch: enable built-in bicubic upscaler by default
            let firstKey = "first_launch_done"
            if !UserDefaults.standard.bool(forKey: firstKey) {
                UserDefaults.standard.set(true, forKey: firstKey)
                UserDefaults.standard.set("builtin_bicubic", forKey: "default_upscaler_id")
                selectedUpscalerId = "builtin_bicubic"
            } else {
                if let saved = UserDefaults.standard.string(forKey: "default_upscaler_id"), !saved.isEmpty {
                    selectedUpscalerId = saved
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ModelDownloaded"))) { _ in
            reloadModels()
        }
        .background(Color(UIColor.systemBackground))
        .sheet(isPresented: $showingSamplerList) {
            NavigationView {
                List {
                    ForEach(samplers, id: \.self) { s in
                        HStack {
                            Text(s)
                            Spacer()
                            if s == sampler {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.mint)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            sampler = s
                            showingSamplerList = false
                        }
                    }
                }
                .navigationTitle("Select Sampler")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { showingSamplerList = false }
                    }
                }
            }
        }
    }

    // MARK: - Notification Methods
    private func checkNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.notificationPermissionGranted = settings.authorizationStatus == .authorized
                if !self.notificationPermissionGranted {
                    self.enableNotifications = false
                }
            }
        }
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                self.notificationPermissionGranted = granted
                self.enableNotifications = granted
                if let error = error {
                    print("Notification permission error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func sendGenerationCompleteNotification() {
        guard enableNotifications && notificationPermissionGranted else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Image Generation Complete"
        content.body = "Your AI-generated image is ready!"
        content.sound = .default
        content.badge = NSNumber(value: 1)
        
        // Add custom category for potential actions
        content.categoryIdentifier = "IMAGE_GENERATION_COMPLETE"
        
        let request = UNNotificationRequest(
            identifier: "image_generation_\(UUID().uuidString)",
            content: content,
            trigger: nil // Immediate delivery
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule notification: \(error.localizedDescription)")
            }
        }
    }
    
    private func sendGenerationStartedNotification() {
        guard enableNotifications && notificationPermissionGranted else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Image Generation Started"
        content.body = "Generating your image with \(Int(steps)) steps..."
        content.sound = nil // No sound for start notification
        
        let request = UNNotificationRequest(
            identifier: "image_generation_started_\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule start notification: \(error.localizedDescription)")
            }
        }
    }

    private func reloadModels() {
        downloadedModels = ModelStorage.shared.getDownloadedModels()
        if activeModelId == nil, let first = downloadedModels.first { activeModelId = first.id }
        modelAvailable = ModelStorage.shared.getActiveModelResourcesURL() != nil
        // Compute or refresh folder sizes asynchronously
        Task.detached(priority: .utility) {
            var sizes: [String: Int64] = [:]
            for model in downloadedModels {
                sizes[model.id] = computeInstalledModelSizeBytes(modelId: model.id)
            }
            await MainActor.run { self.modelFolderSizes = sizes }
        }
        // Load available upscalers from downloaded models (by naming rule)
        upscalers = downloadedModels.filter { isUpscalerModel($0) }
    }

    private func subscribeProgress() {
        NotificationCenter.default.addObserver(forName: StableDiffusionService.progressNotification, object: nil, queue: .main) { note in
            if let img = note.userInfo?["image"] as? UIImage {
                let keep = reduceMemory ? 3 : 6
                frames.append(img)
                if frames.count > keep { frames.removeFirst(frames.count - keep) }
            }
            if let step = note.userInfo?["step"] as? Int { currentStep = step }
        }
    }

    private func generate() {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isGenerating = true
        frames.removeAll()
        finalImage = nil
        
        // Send notification that generation started
        sendGenerationStartedNotification()
        
        let seedValue: UInt32 = {
            if let seedInt = UInt32(seed), seedInt > 0 {
                return seedInt
            }
            return 0 // Random
        }()
        
        let settings = StableDiffusionService.GenerationSettings(
            stepCount: Int(steps),
            guidanceScale: Float(guidance),
            negativePrompt: negativePrompt,
            sampler: sampler,
            imageCount: imageCount,
            previewLatent: previewLatent,
            previewDenoised: previewDenoised,
            reduceMemory: reduceMemory,
            computeUnits: computeUnitsKey,
            seed: seedValue,
            upscalerId: selectedUpscalerId == "none" ? nil : selectedUpscalerId
        )
        currentStep = 0
        Task {
            do {
                var img = try await StableDiffusionService.shared.generateImage(from: prompt, settings: settings)
                await MainActor.run {
                    finalImage = img
                    isGenerating = false
                    // Send notification that generation is complete
                    sendGenerationCompleteNotification()
                }
                // Persist to Gallery
                persistToGallery(image: img, settings: settings)
            } catch {
                await MainActor.run {
                    isGenerating = false
                    print("Error generating: \(error)")
                    // Optionally send error notification
                    if enableNotifications && notificationPermissionGranted {
                        let content = UNMutableNotificationContent()
                        content.title = "Image Generation Failed"
                        content.body = "There was an error generating your image."
                        content.sound = .default
                        let request = UNNotificationRequest(
                            identifier: "image_generation_error_\(UUID().uuidString)",
                            content: content,
                            trigger: nil
                        )
                        UNUserNotificationCenter.current().add(request)
                    }
                }
            }
        }
    }

    // MARK: - Gallery persistence
    private func persistToGallery(image: UIImage, settings: StableDiffusionService.GenerationSettings) {
        // Defer to GalleryStore (added in a separate file)
        let meta = GalleryEntry.Metadata(
            prompt: prompt,
            negativePrompt: negativePrompt,
            modelId: activeModelId ?? "",
            modelName: downloadedModels.first(where: { $0.id == activeModelId })?.name ?? "",
            steps: Int(steps),
            guidance: Float(guidance),
            sampler: sampler,
            seed: settings.seed,
            upscalerId: settings.upscalerId,
            upscalerName: upscalers.first(where: { $0.id == settings.upscalerId })?.name,
            timestamp: Date()
        )
        Task {
            do {
                try await GalleryStore.shared.save(image: image, metadata: meta)
                NotificationCenter.default.post(name: GalleryStore.galleryUpdatedNotification, object: nil)
            } catch {
                print("Gallery save failed: \(error)")
            }
        }
    }

    // MARK: - Model size grouping helpers
    private func groupedModelsBySize() -> [String: [StableDiffusionModel]] {
        var groups: [String: [StableDiffusionModel]] = [:]
        for model in downloadedModels {
            let sizeBytes = modelFolderSizes[model.id] ?? 0
            let category = sizeCategory(forBytes: sizeBytes)
            groups[category, default: []].append(model)
        }
        // If sizes not yet computed, place unknowns in "Uncategorized"
        if groups.isEmpty && !downloadedModels.isEmpty {
            groups["Uncategorized"] = downloadedModels
        } else {
            for key in groups.keys {
                groups[key]?.sort { $0.name < $1.name }
            }
        }
        return groups
    }

    private func sizeCategory(forBytes bytes: Int64) -> String {
        // Heuristics (adjust as needed):
        // Small: < 1.5 GB; Medium: 1.5–3 GB; Large: 3–5 GB; XL: > 5 GB
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if bytes <= 0 {
            return "Uncategorized"
        } else if gb < 1.5 {
            return "Small (<1.5 GB)"
        } else if gb < 3.0 {
            return "Medium (1.5–3 GB)"
        } else if gb < 5.0 {
            return "Large (3–5 GB)"
        } else {
            return "XL (>5 GB)"
        }
    }

    private func sizeCategorySort(a: String, b: String) -> Bool {
        func rank(_ s: String) -> Int {
            switch s {
            case "Small (<1.5 GB)": return 0
            case "Medium (1.5–3 GB)": return 1
            case "Large (3–5 GB)": return 2
            case "XL (>5 GB)": return 3
            case "Uncategorized": return 4
            default: return 5
            }
        }
        let ra = rank(a), rb = rank(b)
        if ra == rb { return a < b }
        return ra < rb
    }

    private func computeInstalledModelSizeBytes(modelId: String) -> Int64 {
        // Sum directory size for installed model folder
        let fm = FileManager.default
        // The installed folder is under Documents/StableDiffusionModels/<modelId>
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = docs.appendingPathComponent("StableDiffusionModels").appendingPathComponent(modelId)
        guard fm.fileExists(atPath: base.path) else { return 0 }
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                do {
                    let vals = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    if vals.isRegularFile == true, let fileSize = vals.fileSize {
                        total += Int64(fileSize)
                    }
                } catch {
                    // ignore
                }
            }
        }
        return total
    }

    // MARK: - Upscaler identification
    private func isUpscalerModel(_ model: StableDiffusionModel) -> Bool {
        let id = model.id.lowercased()
        let name = model.name.lowercased()
        if id == "realesrgan" { return true }
        if id.contains("esrgan") || id.contains("upscale") { return true }
        if name.contains("esrgan") || name.contains("upscale") { return true }
        return false
    }
}

// MARK: - Compute Units Mapping
extension ImageLabView {
    private var computeUnitsKey: String {
        switch selectedCompute {
        case 0: return "cpuAndNeural"
        case 1: return "cpuAndGPU"
        default: return "all"
        }
    }
}

#Preview {
    ImageLabView()
        .preferredColorScheme(.dark)
}
