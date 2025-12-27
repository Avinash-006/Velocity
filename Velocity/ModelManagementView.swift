import SwiftUI

struct ModelManagementView: View {
    @State private var availableModels: [StableDiffusionModel] = []
    @State private var downloadedModels: [StableDiffusionModel] = []
    @State private var isDownloading = false
    @State private var downloadProgress: [String: Double] = [:]
    @State private var activeModelId: String? = ModelStorage.shared.getActiveModelId()
    @State private var allowDownloads: Bool = UserDefaults.standard.bool(forKey: "allow_model_downloads")
    @State private var pendingDownload: StableDiffusionModel? = nil
    @State private var showConsent: Bool = false
    @State private var bytesLabel: [String: String] = [:]
    @State private var lastBytesInfo: [String: (time: CFAbsoluteTime, written: Int64)] = [:]
    @State private var customModelURL: String = ""
    @State private var showFileImporter: Bool = false
    @State private var importing: Bool = false
    @State private var isUnzipping: Bool = false
    @State private var unzippingModelId: String? = nil
    @State private var unzipProgress: Double = 0
    @State private var showDownloadSheet: Bool = false
    @State private var sheetModel: StableDiffusionModel? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Model Management")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button(action: refreshModels) {
                    Image(systemName: "arrow.clockwise")
                        .font(.title2)
                        .foregroundColor(.mint)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            ScrollView {
                LazyVStack(spacing: 16) {
                    // Available Models Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Available Models")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)

                        // Group available by declared size string
                        let grouped = groupAvailableBySize(availableModels)
                        ForEach(grouped.sorted(by: { sizeRank($0.key) < sizeRank($1.key) }), id: \.key) { (category, models) in
                            if !models.isEmpty {
                                Text(category)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                ForEach(models) { model in
                                    ModelCardView(
                                        model: model,
                                        isDownloaded: downloadedModels.contains(where: { $0.id == model.id }),
                                        isDownloading: isDownloading && downloadProgress[model.id] != nil,
                                        downloadProgress: downloadProgress[model.id] ?? 0,
                                        bytesString: bytesLabel[model.id],
                                        onDownload: { startDownloadFlow(model) }
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    // Add by URL
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add by Hugging Face or Zip URL")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        HStack(spacing: 8) {
                            TextField("https://huggingface.co/<org>/<repo> or direct .zip/.mlmodel", text: $customModelURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .padding(10)
                                .background(.ultraThinMaterial)
                                .cornerRadius(10)
                            Button("Download") {
                                let trimmed = customModelURL.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard trimmed.isEmpty == false else { return }
                                let id = trimmed.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "/", with: "-")
                                let model = StableDiffusionModel(id: id, name: id, description: "Custom model", size: "~? GB", downloadUrl: trimmed)
                                startDownloadFlow(model)
                            }
                            .disabled(isDownloading || customModelURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Text("Tip: Paste the repo URL (we'll fetch compiled files) or a direct .zip/.mlmodel.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 20)
                    
                    // Import from Files
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Import from Files App")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        HStack(spacing: 8) {
                            Button {
                                showFileImporter = true
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                    Text(importing ? "Importing…" : "Choose .zip / .mlmodel / .mlmodelc / folder")
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.mint)
                                .cornerRadius(10)
                            }
                            .disabled(importing)
                        }
                        Text("Tip: Pick a compiled CoreML model folder or an archive.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 20)
                    
                    // Downloaded Models Section (grouped by installed size)
                    if !downloadedModels.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Downloaded Models")
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)

                            let grouped = groupInstalledBySize(downloadedModels)
                            ForEach(grouped.sorted(by: { sizeRank($0.key) < sizeRank($1.key) }), id: \.key) { (category, models) in
                                if !models.isEmpty {
                                    Text(category)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    ForEach(models) { model in
                                        DownloadedModelCardView(
                                            model: model,
                                            isActive: activeModelId == model.id,
                                            onActivate: { setActive(model) },
                                            onDelete: { deleteModel(model) }
                                        )
                                    }
                                }
                            }
                            // Static Upscaler card
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("2× Upscaler (Bicubic)")
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text("Lightweight post-process upscale to 1024×1024")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.title3)
                                    .foregroundColor(.mint)
                            }
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(.ultraThinMaterial)
                            )
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .background(Color(UIColor.systemBackground))
        .overlay {
            if isUnzipping {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView().progressViewStyle(.circular)
                        Text("Installing model…")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        if let id = unzippingModelId {
                            Text(id)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .cornerRadius(14)
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showDownloadSheet) {
            if let m = sheetModel {
                VStack(spacing: 16) {
                    // CPU animation (morphing)
                    MorphingCPU()
                        .frame(width: 64, height: 64)
                    Text(isUnzipping ? "Extracting \(m.name)" : "Downloading \(m.name)")
                        .font(.headline)
                    if isUnzipping {
                        ProgressView(value: unzipProgress)
                            .frame(maxWidth: 380)
                        Text(String(format: "%.0f%%", unzipProgress * 100))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if let p = downloadProgress[m.id] {
                        ProgressView(value: p)
                            .frame(maxWidth: 380)
                        Text(String(format: "%.0f%%", p * 100))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ProgressView().progressViewStyle(.circular)
                    }
                    if let label = bytesLabel[m.id] {
                        Text(label).font(.caption).foregroundColor(.secondary)
                    }
                    Button("Hide") { showDownloadSheet = false }
                        .foregroundColor(.mint)
                        .padding(.top, 6)
                }
                .padding(24)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(16)
                .presentationDetents([.height(260)])
            }
        }
        .onAppear {
            loadModels()
            NotificationCenter.default.addObserver(forName: StableDiffusionService.bytesNotification, object: nil, queue: .main) { note in
                guard let modelId = note.userInfo?["modelId"] as? String,
                      let written = note.userInfo?["written"] as? Int64,
                      let expected = note.userInfo?["expected"] as? Int64,
                      expected > 0 else { return }
                let now = CFAbsoluteTimeGetCurrent()
                let prev = lastBytesInfo[modelId]
                let mbW = Double(written) / (1024.0 * 1024.0)
                let mbT = Double(expected) / (1024.0 * 1024.0)
                var speedStr = ""
                if let prev = prev, now > prev.time {
                    let deltaB = max(0, written - prev.written)
                    let deltaT = now - prev.time
                    if deltaT > 0 {
                        let mbps = (Double(deltaB) / (1024.0 * 1024.0)) / deltaT
                        speedStr = String(format: " • %.2f MB/s", mbps)
                    }
                }
                lastBytesInfo[modelId] = (time: now, written: written)
                bytesLabel[modelId] = String(format: "%.1f MB / %.1f MB%@", mbW, mbT, speedStr)
            }
            NotificationCenter.default.addObserver(forName: StableDiffusionService.unzipStartedNotification, object: nil, queue: .main) { note in
                isUnzipping = true
                unzippingModelId = note.userInfo?["modelId"] as? String
                unzipProgress = 0
            }
            NotificationCenter.default.addObserver(forName: StableDiffusionService.unzipFinishedNotification, object: nil, queue: .main) { _ in
                isUnzipping = false
                unzippingModelId = nil
                showDownloadSheet = false
            }
            NotificationCenter.default.addObserver(forName: StableDiffusionService.unzipProgressNotification, object: nil, queue: .main) { note in
                guard let p = note.userInfo?["progress"] as? Double else { return }
                unzipProgress = p
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importing = true
                Task {
                    do {
                        let model = try await ModelStorage.shared.importModel(from: url)
                        await MainActor.run {
                            downloadedModels = ModelStorage.shared.getDownloadedModels()
                            if activeModelId == nil { activeModelId = model.id }
                            importing = false
                        }
                    } catch {
                        importing = false
                        print("Import failed: \(error)")
                    }
                }
            case .failure:
                break
            }
        }
        .alert("Allow large model downloads?", isPresented: $showConsent, presenting: pendingDownload) { model in
            Button("Allow Once") {
                startDownload(model)
            }
            Button("Always Allow") {
                allowDownloads = true
                UserDefaults.standard.set(true, forKey: "allow_model_downloads")
                startDownload(model)
            }
            Button("Cancel", role: .cancel) {
                pendingDownload = nil
            }
        } message: { model in
            Text("This will download ‘\(model.name)’ (several GB). Ensure Wi‑Fi and enough storage.")
        }
    }
    
    private func refreshModels() {
        loadModels()
    }
    
    private func loadModels() {
        // Load ALL available models from Joyfusion repository
        availableModels = [
            // Large Einsum Models (1.97 GB)
            StableDiffusionModel(
                id: "analog-diffusion-vae-split-einsum-chunked-256-256",
                name: "Analog Diffusion (Split Einsum 256×256)",
                description: "Analog photography style model with split einsum optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/Analog-Diffusion-vae-split_einsum-chunked-256_256.zip"
            ),
            StableDiffusionModel(
                id: "analog-diffusion-vae-split-einsum-chunked-512x512",
                name: "Analog Diffusion (Split Einsum 512×512)",
                description: "Analog photography style model with split einsum optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/Analog-Diffusion_vae_split-einsum-chunked_512x512.zip"
            ),
            StableDiffusionModel(
                id: "counterfeit-v2.5-vae-split-einsum-chunked-256x256",
                name: "Counterfeit v2.5 (Split Einsum 256×256)",
                description: "High-quality anime model with split einsum optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/Counterfeit-V2.5_vae_split-einsum_chunked-256x256.zip"
            ),
            StableDiffusionModel(
                id: "counterfeit-v2.5-vae-split-einsum-chunked-512x512",
                name: "Counterfeit v2.5 (Split Einsum 512×512)",
                description: "High-quality anime model with split einsum optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/Counterfeit-V2.5_vae_split-einsum_chunked_512x512.zip"
            ),
            StableDiffusionModel(
                id: "dreamshaper-vae-split-einsum-chunked-512x512",
                name: "DreamShaper (Split Einsum 512×512)",
                description: "High-quality artistic model with split einsum optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/DreamShaper_vae-split-einsum_chunked_512x512.zip"
            ),
            StableDiffusionModel(
                id: "lyriel-v1-5-vae-split-einsum-chunked",
                name: "Lyriel v1.5 (Split Einsum)",
                description: "Anime-style model with split einsum optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/Lyriel-v1-5_vae_split-einsum_chunked.zip"
            ),
            StableDiffusionModel(
                id: "orange-mixs-vae-split-einsum-chunked-256-256",
                name: "Orange Mixs (Split Einsum 256×256)",
                description: "Orange Mix style model with split einsum optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/OrangeMixs-vae-split_einsum-chunked-256_256.zip"
            ),
            StableDiffusionModel(
                id: "orange-mixs-vae-split-einsum-chunked-512x512",
                name: "Orange Mixs (Split Einsum 512×512)",
                description: "Orange Mix style model with split einsum optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/OrangeMixs_vae_split_einsum-chunked_512x512.zip"
            ),
            StableDiffusionModel(
                id: "openjourney-vae-split-einsum-chunked-512-512",
                name: "OpenJourney (Split Einsum 512×512)",
                description: "Midjourney-style model with split einsum optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/openjourney-vae-split_einsum-chunked-512_512.zip"
            ),
            StableDiffusionModel(
                id: "dreamshaper-v8-split-einsum",
                name: "DreamShaper v8 (Split Einsum)",
                description: "DreamShaper v8 with split einsum optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/dreamshaper_v8_split-einsum.zip"
            ),
            StableDiffusionModel(
                id: "epicrealism-v5-split-einsum",
                name: "EpicRealism v5 (Split Einsum)",
                description: "Photorealistic model with split einsum optimization",
                size: "1.96 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/epicrealism_v5_split-einsum.zip"
            ),
            StableDiffusionModel(
                id: "meinaunreal-v41-split-einsum",
                name: "MeinaUnreal v41 (Split Einsum)",
                description: "Unreal engine style model with split einsum optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/meinaunreal_v41_split-einsum.zip"
            ),
            StableDiffusionModel(
                id: "deliberate-v2-vae-chunked",
                name: "Deliberate v2 (VAE Chunked)",
                description: "Deliberate model with VAE chunking optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/deliberate_v2_vae_chunked.zip"
            ),
            StableDiffusionModel(
                id: "disney-pixar-cartoon-v10-vae-chunked",
                name: "Disney Pixar Cartoon v10 (VAE Chunked)",
                description: "Cartoon-style model with VAE chunking optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/disneyPixarCartoon_v10_vae_chunked.zip"
            ),
            StableDiffusionModel(
                id: "dreamshaper-v8-512x512-chunked",
                name: "DreamShaper v8 (512×512 Chunked)",
                description: "DreamShaper v8 with chunking optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/dreamshaper_v8_512x512.zip"
            ),
            StableDiffusionModel(
                id: "dreamshaper-v8-512x768-chunked",
                name: "DreamShaper v8 (512×768 Chunked)",
                description: "DreamShaper v8 portrait model with chunking optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/dreamshaper_v8_512x768.zip"
            ),
            StableDiffusionModel(
                id: "dreamshaper-v8-768x512-chunked",
                name: "DreamShaper v8 (768×512 Chunked)",
                description: "DreamShaper v8 landscape model with chunking optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/dreamshaper_v8_768x512.zip"
            ),
            StableDiffusionModel(
                id: "epicrealism-v5-512x512-chunked",
                name: "EpicRealism v5 (512×512 Chunked)",
                description: "Photorealistic model with chunking optimization",
                size: "1.96 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/epicrealism_v5_512x512.zip"
            ),
            StableDiffusionModel(
                id: "epicrealism-v5-512x768-chunked",
                name: "EpicRealism v5 (512×768 Chunked)",
                description: "Photorealistic portrait model with chunking optimization",
                size: "1.96 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/epicrealism_v5_512x768.zip"
            ),
            StableDiffusionModel(
                id: "epicrealism-v5-768x512-chunked",
                name: "EpicRealism v5 (768×512 Chunked)",
                description: "Photorealistic landscape model with chunking optimization",
                size: "1.96 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/epicrealism_v5_768x512.zip"
            ),
            StableDiffusionModel(
                id: "meinaunreal-v41-512x512-chunked",
                name: "MeinaUnreal v41 (512×512 Chunked)",
                description: "Unreal engine style model with chunking optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/meinaunreal_v41_512x512.zip"
            ),
            StableDiffusionModel(
                id: "meinaunreal-v41-512x768-chunked",
                name: "MeinaUnreal v41 (512×768 Chunked)",
                description: "Unreal engine portrait model with chunking optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/meinaunreal_v41_512x768.zip"
            ),
            StableDiffusionModel(
                id: "meinaunreal-v41-768x512-chunked",
                name: "MeinaUnreal v41 (768×512 Chunked)",
                description: "Unreal engine landscape model with chunking optimization",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/meinaunreal_v41_768x512.zip"
            ),
            StableDiffusionModel(
                id: "bra-beautiful-realistic-brav5-original-512x768",
                name: "BRA Beautiful Realistic v5 (512×768)",
                description: "Beautiful realistic model optimized for portrait generation",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/braBeautifulRealistic_brav5_original_512x768.zip"
            ),
            StableDiffusionModel(
                id: "grapefruit41-original-512x768",
                name: "Grapefruit v41 (512×768)",
                description: "Grapefruit model optimized for portrait generation",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/grapefruit41_original_512x768.zip"
            ),
            StableDiffusionModel(
                id: "lyriel-v16-original-512x768",
                name: "Lyriel v16 (512×768)",
                description: "Lyriel v16 optimized for portrait generation",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/lyriel_v16_original_512x768.zip"
            ),
            
            // Extra Large Models (3.56 GB)
            StableDiffusionModel(
                id: "dreamshaper-vae-split-einsum-chunked-256-256",
                name: "DreamShaper (Split Einsum 256×256)",
                description: "High-quality artistic model with split einsum optimization",
                size: "3.56 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/DreamShaper_vae_split-einsum_chunked_256-256.zip"
            ),
            StableDiffusionModel(
                id: "coreml-lazymixplus-v1-vae-split-einsum-chunked",
                name: "CoreML LazyMixPlus v1 (Split Einsum)",
                description: "CoreML optimized LazyMixPlus with split einsum",
                size: "3.56 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/coreml-LazyMixPlus-v1_vae_split-einsum_chunked.zip"
            ),
            
            // Medium Models (1.11 GB)
            StableDiffusionModel(
                id: "lazymixplus-v10-original-8bits",
                name: "LazyMixPlus v10 (8-bit)",
                description: "LazyMixPlus model with 8-bit quantization",
                size: "1.11 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/LazyMixPlus-v10_original_8bits.zip"
            ),
            StableDiffusionModel(
                id: "dreamshaper-v8-original-8bits",
                name: "DreamShaper v8 (8-bit)",
                description: "DreamShaper v8 with 8-bit quantization",
                size: "1.11 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/dreamshaper_v8_original_8bits.zip"
            ),
            StableDiffusionModel(
                id: "epicrealism-v5-original-8bits",
                name: "EpicRealism v5 (8-bit)",
                description: "EpicRealism v5 with 8-bit quantization",
                size: "1.11 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/epicrealism_v5_original_8bits.zip"
            ),
            StableDiffusionModel(
                id: "disney-pixar-cartoon-v10-original-8bits",
                name: "Disney Pixar Cartoon v10 (8-bit)",
                description: "Disney/Pixar cartoon style with 8-bit quantization",
                size: "1.11 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/disneyPixarCartoon_v10_original_8bits.zip"
            ),
            StableDiffusionModel(
                id: "lyriel-v16-original-8bits",
                name: "Lyriel v16 (8-bit)",
                description: "Lyriel v16 with 8-bit quantization",
                size: "1.11 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/lyriel_v16_original_8bits.zip"
            ),
            
            // Small Models (918 MB - 647 MB)
            StableDiffusionModel(
                id: "disney-cartoon-10-se2-bit6",
                name: "Disney Cartoon v10 (6-bit)",
                description: "Disney cartoon style with 6-bit quantization",
                size: "918 MB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/disney_cartoon_10_se2_bit6.zip"
            ),
            StableDiffusionModel(
                id: "dreamshaper-8-se2-bit6",
                name: "DreamShaper v8 (6-bit)",
                description: "DreamShaper v8 with 6-bit quantization",
                size: "918 MB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/dreamshaper_8_se2_bit6.zip"
            ),
            StableDiffusionModel(
                id: "epicrealism-5-se2-bit6",
                name: "EpicRealism v5 (6-bit)",
                description: "EpicRealism v5 with 6-bit quantization",
                size: "914 MB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/epicrealism_5_se2_bit6.zip"
            ),
            StableDiffusionModel(
                id: "lazymix-v3-se2-bit6",
                name: "LazyMix v3 (6-bit)",
                description: "LazyMix v3 with 6-bit quantization",
                size: "919 MB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/lazymix_v3_se2_bit6.zip"
            ),
            StableDiffusionModel(
                id: "lyriel-v16-se2-bit6",
                name: "Lyriel v16 (6-bit)",
                description: "Lyriel v16 with 6-bit quantization",
                size: "918 MB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/lyriel_v16_se2_bit6.zip"
            ),
            StableDiffusionModel(
                id: "dreamshaper-8-se2-bit4",
                name: "DreamShaper v8 (4-bit)",
                description: "DreamShaper v8 with 4-bit quantization",
                size: "647 MB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/dreamshaper_8_se2_bit4.zip"
            ),
            
            // Extra Large Models (5-6 GB)
            StableDiffusionModel(
                id: "sdxl-ronghua-v30-original-128-128",
                name: "SDXL Ronghua v30 (128×128)",
                description: "SDXL Ronghua model with original weights",
                size: "5.33 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/SDXLRonghua_v30_original_128_128.zip"
            ),
            StableDiffusionModel(
                id: "animaginexl-8bits-64-96",
                name: "AnimagineXL (8-bit 64×96)",
                description: "AnimagineXL with 8-bit quantization",
                size: "3.51 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/animaginexl_8bits_64_96.zip"
            ),
            StableDiffusionModel(
                id: "animaginexl-original-128-128",
                name: "AnimagineXL (Original 128×128)",
                description: "AnimagineXL with original weights",
                size: "6.44 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/animaginexl_original_128_128.zip"
            ),
            StableDiffusionModel(
                id: "juggernautxl-v5-original-128-128",
                name: "JuggernautXL v5 (128×128)",
                description: "JuggernautXL v5 with original weights",
                size: "6.41 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/juggernautXL_v5_original_128_128.zip"
            ),
            StableDiffusionModel(
                id: "juggernautxl-v5-original-8bits-64-96",
                name: "JuggernautXL v5 (8-bit 64×96)",
                description: "JuggernautXL v5 with 8-bit quantization",
                size: "3.52 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/juggernautXL_v5_original_8bits_64_96.zip"
            ),
            StableDiffusionModel(
                id: "dynavisionxl-0534-original-128-128",
                name: "DynaVisionXL v0534 (128×128)",
                description: "DynaVisionXL with original weights",
                size: "6.42 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/dynavisionXL0534_originl_128_128.zip"
            ),
            
            // Special Models
            StableDiffusionModel(
                id: "compvis-stable-diffusion-v1-4-chunked230225",
                name: "CompVis SD v1.4 (Chunked)",
                description: "Original CompVis Stable Diffusion v1.4 with chunking",
                size: "1.97 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/CompVis-stable-diffusion-v1-4_chunked230225.zip"
            ),
            StableDiffusionModel(
                id: "ofasys-small-stable-diffusion-v0-coreml-chunked",
                name: "OFA-Sys Small SD v0 (CoreML)",
                description: "OFA-Sys small Stable Diffusion v0 CoreML model",
                size: "2.53 GB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/OFA-Sys_small-stable-diffusion-v0_coreml_chunked.zip"
            ),
            StableDiffusionModel(
                id: "disco-delirium-xl-v1-2-safetensors",
                name: "DiscoDeliriumXL v1.2",
                description: "DiscoDeliriumXL v1.2 in SafeTensors format",
                size: "244 MB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/DiscoDeliriumXL-v1.2.safetensors"
            ),
            StableDiffusionModel(
                id: "realesrgan",
                name: "RealESRGAN",
                description: "RealESRGAN upscaling model",
                size: "62.1 MB",
                downloadUrl: "https://huggingface.co/Norton0924/Joyfusion/resolve/main/RealESRGAN.zip"
            )
        ]
        
        // Load downloaded models from local storage
        downloadedModels = ModelStorage.shared.getDownloadedModels()
        activeModelId = ModelStorage.shared.getActiveModelId()
    }
    
    private func startDownloadFlow(_ model: StableDiffusionModel) {
        if !allowDownloads {
            pendingDownload = model
            showConsent = true
            return
        }
        sheetModel = model
        showDownloadSheet = true
        startDownload(model)
    }
    
    private func setActive(_ model: StableDiffusionModel) {
        ModelStorage.shared.setActiveModelId(model.id)
        activeModelId = model.id
    }
    
    private func startDownload(_ model: StableDiffusionModel) {
        isDownloading = true
        downloadProgress[model.id] = 0.0
        
        Task {
            do {
                try await ModelStorage.shared.downloadModel(model) { progress in
                    Task { @MainActor in
                        downloadProgress[model.id] = progress
                    }
                }
                
                await MainActor.run {
                    downloadProgress.removeValue(forKey: model.id)
                    isDownloading = false
                    // Refresh the downloaded models list
                    downloadedModels = ModelStorage.shared.getDownloadedModels()
                    // Keep active id if set, else set to the newly installed folder id
                    if activeModelId == nil { activeModelId = ModelStorage.shared.getActiveModelId() }
                }
            } catch {
                await MainActor.run {
                    downloadProgress.removeValue(forKey: model.id)
                    isDownloading = false
                    print("Download failed: \(error)")
                }
            }
        }
    }

    private func deleteModel(_ model: StableDiffusionModel) {
        Task {
            do {
                try await ModelStorage.shared.deleteModel(model)
                await MainActor.run {
                    downloadedModels.removeAll { $0.id == model.id }
                }
            } catch {
                print("Delete failed: \(error)")
            }
        }
    }
}

// Simple rotating gear overlay used in download sheet
fileprivate struct RotatingGear: View {
    @State private var angle: Double = 0
    var body: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 28, weight: .regular))
            .foregroundColor(.mint)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

fileprivate struct MorphingCPU: View {
    @State private var step: Int = 0
    private let symbols = ["cpu", "square.grid.2x2", "rectangle.3.group", "circle.dashed", "cpu"]
    var body: some View {
        Image(systemName: symbols[step % symbols.count])
            .font(.system(size: 54, weight: .regular))
            .foregroundColor(.mint)
            .onAppear {
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    step = (step + 1) % symbols.count
                }
            }
    }
}

// MARK: - Grouping helpers
extension ModelManagementView {
    private func groupAvailableBySize(_ models: [StableDiffusionModel]) -> [String: [StableDiffusionModel]] {
        var groups: [String: [StableDiffusionModel]] = [:]
        for m in models {
            let cat = declaredSizeCategory(m.size)
            groups[cat, default: []].append(m)
        }
        for key in groups.keys { groups[key]?.sort { $0.name < $1.name } }
        return groups
    }

    private func groupInstalledBySize(_ models: [StableDiffusionModel]) -> [String: [StableDiffusionModel]] {
        var groups: [String: [StableDiffusionModel]] = [:]
        for m in models {
            let bytes = computeInstalledModelSizeBytes(modelId: m.id)
            let cat = installedSizeCategory(bytes: bytes)
            groups[cat, default: []].append(m)
        }
        for key in groups.keys { groups[key]?.sort { $0.name < $1.name } }
        return groups
    }

    private func declaredSizeCategory(_ size: String) -> String {
        // Expect formats like "1.97 GB", "918 MB", fallback to Uncategorized
        let parts = size.split(separator: " ")
        guard parts.count >= 2, let value = Double(parts[0]) else { return "Uncategorized" }
        let unit = parts[1].uppercased()
        let bytes: Double
        if unit.hasPrefix("GB") { bytes = value * 1024 * 1024 * 1024 }
        else if unit.hasPrefix("MB") { bytes = value * 1024 * 1024 }
        else { bytes = value }
        return installedSizeCategory(bytes: Int64(bytes))
    }

    private func installedSizeCategory(bytes: Int64) -> String {
        if bytes <= 0 { return "Uncategorized" }
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb < 1.5 { return "Small (<1.5 GB)" }
        if gb < 3.0 { return "Medium (1.5–3 GB)" }
        if gb < 5.0 { return "Large (3–5 GB)" }
        return "XL (>5 GB)"
    }

    private func sizeRank(_ category: String) -> Int {
        switch category {
        case "Small (<1.5 GB)": return 0
        case "Medium (1.5–3 GB)": return 1
        case "Large (3–5 GB)": return 2
        case "XL (>5 GB)": return 3
        case "Uncategorized": return 4
        default: return 5
        }
    }

    private func computeInstalledModelSizeBytes(modelId: String) -> Int64 {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = docs.appendingPathComponent("StableDiffusionModels").appendingPathComponent(modelId)
        guard fm.fileExists(atPath: base.path) else { return 0 }
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals.isRegularFile == true, let fileSize = vals.fileSize {
                    total += Int64(fileSize)
                }
            }
        }
        return total
    }
}

struct ModelCardView: View {
    let model: StableDiffusionModel
    let isDownloaded: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let bytesString: String?
    let onDownload: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(model.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(model.size)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let label = bytesString {
                        Text(label)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    if isDownloading {
                        ProgressView(value: downloadProgress)
                            .frame(width: 60)
                    } else {
                        HStack(spacing: 8) {
                            Button("Open Link") {
                                if let url = URL(string: model.downloadUrl) { UIApplication.shared.open(url) }
                            }
                            .font(.caption)
                            .foregroundColor(.mint)

                            if !isDownloaded {
                                Button("Download", action: onDownload)
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(.mint)
                                    .cornerRadius(12)
                            } else {
                                Label("Installed", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

struct DownloadedModelCardView: View {
    let model: StableDiffusionModel
    let isActive: Bool
    let onActivate: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    if isActive {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                Text("Downloaded • \(model.size)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(isActive ? "Active" : "Activate", action: onActivate)
                .font(.caption)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? Color.green : Color.mint)
                .cornerRadius(12)
                .disabled(isActive)
            
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
                    .font(.title3)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

#Preview {
    ModelManagementView()
        .preferredColorScheme(.dark)
}
