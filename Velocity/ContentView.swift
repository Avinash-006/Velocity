import SwiftUI
import Speech
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import PDFKit

// Local models and service
struct Attachment: Identifiable, Hashable {
    let id = UUID()
    let filename: String
    let mimeType: String
    let data: Data
}

struct ChatMessage: Identifiable, Hashable {
    let id = UUID()
    let isUser: Bool
    let text: String
    let attachments: [Attachment]
}

struct Chat: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var messages: [ChatMessageCodable]
}

struct ChatMessageCodable: Codable, Hashable {
    let isUser: Bool
    let text: String
}

final class LocalGeminiService {
    enum ServiceError: Error { case missingApiKey, badResponse, decodingFailed, requestFailed(statusCode: Int) }
    private let session: URLSession = .shared
    private let model: String = "gemini-1.5-flash"
    func generateResponse(for userText: String, attachments: [Attachment] = [], history: [ChatMessage] = []) async throws -> String {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String, !apiKey.isEmpty else { throw ServiceError.missingApiKey }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)") else { throw ServiceError.badResponse }
        var parts: [[String: Any]] = []
        if !history.isEmpty {
            let joined = history.map { ($0.isUser ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n")
            parts.append(["text": "Context (most recent first):\n\(joined.suffix(4000))"])
        }
        if !userText.isEmpty { parts.append(["text": userText]) }
        for file in attachments {
            parts.append(["inlineData": ["mimeType": file.mimeType, "data": file.data.base64EncodedString()]])
        }
        let body: [String: Any] = ["contents": [["role": "user", "parts": parts]]]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            print("Gemini error (\(http.statusCode)): \(message)")
            throw ServiceError.requestFailed(statusCode: http.statusCode)
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let candidates = json["candidates"] as? [[String: Any]],
           let first = candidates.first,
           let content = first["content"] as? [String: Any],
           let partsArr = content["parts"] as? [[String: Any]] {
            let texts = partsArr.compactMap { $0["text"] as? String }
            return texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw ServiceError.decodingFailed
    }
}

struct ContentView: View {
    @State private var text: String = ""
    @State private var isExpanded: Bool = false
    @State private var isListening: Bool = false
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var borderIntensity: Double = 0.0
    @State private var request: SFSpeechAudioBufferRecognitionRequest?
    @State private var messages: [ChatMessage] = []
    @State private var pendingAttachments: [Attachment] = []
    @State private var isSending: Bool = false
    @State private var showFileImporter: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    
    @State private var chats: [Chat] = []
    @State private var currentChatId: UUID = UUID()
    private let gemini = LocalGeminiService()
    
    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    
    private let micGlowColors = [Color.white.opacity(0.8), Color.gray.opacity(0.6)]
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            SidebarView(
                chats: chats,
                currentChatId: currentChatId,
                onNewChat: newChat,
                onLoadChat: loadChat,
                onDeleteChat: deleteChat
            )
        } detail: {
            // Main chat view
            ChatDetailView(
                messages: messages,
                text: $text,
                isExpanded: $isExpanded,
                isListening: isListening,
                isSending: isSending,
                pendingAttachments: $pendingAttachments,
                selectedPhotoItem: $selectedPhotoItem,
                showFileImporter: $showFileImporter,
                onStartListening: startListening,
                onStopListening: stopListening,
                onSendMessage: { Task { await sendMessage() } },
                onPreviewImage: previewImage,
                onRemoveAttachment: { attachment in
                    if let idx = pendingAttachments.firstIndex(of: attachment) {
                        pendingAttachments.remove(at: idx)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(
                        LinearGradient(colors: micGlowColors,
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing),
                        lineWidth: isListening ? CGFloat(1.5 + borderIntensity * 6) : 0
                    )
                    .shadow(color: Color.white.opacity(0.3),
                            radius: isListening ? CGFloat(3 + borderIntensity * 6) : 0)
                    .blur(radius: 3)
                    .animation(.easeInOut(duration: 0.2), value: borderIntensity)
                    .ignoresSafeArea()
            )
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    do {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let data = try Data(contentsOf: url)
                        let filename = url.lastPathComponent
                        let mime = mimeType(for: url) ?? "application/octet-stream"
                        
                        // Limit attachment size to prevent memory issues (10MB max)
                        if data.count > 10 * 1024 * 1024 {
                            print("File too large: \(filename) (\(data.count) bytes)")
                            return
                        }
                        
                        let att = Attachment(filename: filename, mimeType: mime, data: data)
                        pendingAttachments.append(att)
                    } catch {
                        print("File import error: \(error)")
                    }
                }
            case .failure(let error):
                print("File importer failed: \(error)")
            }
        }
        .onChange(of: selectedPhotoItem) { newItem in
            guard let item = newItem else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    // Limit photo size to prevent memory issues (5MB max for photos)
                    if data.count > 5 * 1024 * 1024 {
                        print("Photo too large: \(data.count) bytes")
                        return
                    }
                    
                    let suggestedName = (try? await item.loadTransferable(type: PHLivePhoto.self)) != nil ? "photo.jpg" : "image.jpg"
                    let att = Attachment(filename: suggestedName, mimeType: "image/jpeg", data: data)
                    pendingAttachments.append(att)
                }
            }
        }
        .onAppear { 
            restoreChats()
            setupAudioSession()
        }
        .onDisappear {
            cleanupAudioResources()
        }
    }
    
    // MARK: - Thumbnail preview helper
    private func previewImage(for attachment: Attachment) -> UIImage? {
        if attachment.mimeType.hasPrefix("image/"),
           let image = UIImage(data: attachment.data) {
            return image
        } else if attachment.mimeType == "application/pdf",
                  let document = PDFDocument(data: attachment.data),
                  let page = document.page(at: 0) {
            let pageBounds = page.bounds(for: .mediaBox)
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50))
            return renderer.image { context in
                UIColor.white.setFill()
                context.fill(pageBounds)
                context.cgContext.translateBy(x: 0, y: 50)
                context.cgContext.scaleBy(x: 50 / pageBounds.width, y: -50 / pageBounds.height)
                page.draw(with: .mediaBox, to: context.cgContext)
            }
        }
        return nil
    }
    
    // MARK: - Audio Session Management
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true)
        } catch {
            print("Audio session setup failed: \(error)")
        }
    }
    
    private func cleanupAudioResources() {
        stopListening()
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("Audio session cleanup failed: \(error)")
        }
    }
    
    // MARK: - Speech functions
    private func startListening() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            if authStatus == .authorized {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    if granted {
                        DispatchQueue.main.async {
                            beginRecognition()
                        }
                    } else {
                        print("❌ Microphone permission denied")
                    }
                }
            } else {
                print("❌ Speech recognition not authorized")
            }
        }
    }
    
    private func beginRecognition() {
        // Start background task to prevent termination
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SpeechRecognition") {
            self.stopListening()
        }
        
        request = SFSpeechAudioBufferRecognitionRequest()
        request?.shouldReportPartialResults = true
        
        do {
            let node = audioEngine.inputNode
            let format = node.outputFormat(forBus: 0)
            node.removeTap(onBus: 0)
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                self.request?.append(buffer)
                
                // Safer audio level calculation
                if let channelData = buffer.floatChannelData?[0] {
                    let frameLength = Int(buffer.frameLength)
                    guard frameLength > 0 else { return }
                    
                    let channelDataBuffer = UnsafeBufferPointer(start: channelData, count: frameLength)
                    let sum = channelDataBuffer.reduce(0) { $0 + $1 * $1 }
                    let rms = sqrt(sum / Float(frameLength))
                    let level = max(0.0, min(Double(rms) * 20, 1.0))
                    
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            self.borderIntensity = level
                        }
                    }
                }
            }
            
            audioEngine.prepare()
            try audioEngine.start()
            
            recognitionTask = recognizer?.recognitionTask(with: request!) { result, error in
                if let result = result {
                    DispatchQueue.main.async {
                        self.text = result.bestTranscription.formattedString
                    }
                }
                
                if let error = error {
                    print("Recognition error: \(error)")
                    DispatchQueue.main.async {
                        self.stopListening()
                    }
                }
            }
            
            isListening = true
        } catch {
            print("Audio error: \(error)")
            stopListening()
        }
    }
    
    private func stopListening() {
        guard isListening else { return }
        
        isListening = false
        borderIntensity = 0
        
        // Stop audio engine safely
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        
        // End recognition
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        
        // End background task
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
    
    // MARK: - Gemini send
    private func sendMessage() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, (!trimmed.isEmpty || !pendingAttachments.isEmpty) else { return }
        isSending = true
        let userMsg = ChatMessage(isUser: true, text: trimmed, attachments: pendingAttachments)
        messages.append(userMsg)
        text = ""
        pendingAttachments.removeAll()
        
        // Check if this is an image generation request
        if trimmed.lowercased().hasPrefix("generate image") {
            // Redirect to Image Lab instead of generating in chat
            let botMsg = ChatMessage(isUser: false, text: "Open Image Lab tab to generate images with live preview.", attachments: [])
            messages.append(botMsg)
        } else {
            do {
                let recent = Array(messages.suffix(6))
                let reply = try await gemini.generateResponse(for: userMsg.text, attachments: userMsg.attachments, history: recent)
                var botMsg = ChatMessage(isUser: false, text: "", attachments: [])
                messages.append(botMsg)
                for character in reply {
                    try? await Task.sleep(nanoseconds: 12_000_000)
                    if let lastIndex = messages.indices.last, !messages[lastIndex].isUser {
                        let current = messages[lastIndex]
                        botMsg = ChatMessage(isUser: false, text: current.text + String(character), attachments: [])
                        messages[lastIndex] = botMsg
                    }
                }
            } catch {
                let botMsg = ChatMessage(isUser: false, text: "Error: \(error)", attachments: [])
                messages.append(botMsg)
            }
        }
        isSending = false
        saveCurrentChat()
    }
    
    // MARK: - Image Generation
    // Removed in favor of Image Lab
    
    // MARK: - MIME type helper
    private func mimeType(for url: URL) -> String? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.preferredMIMEType
        }
        return nil
    }
    
    // MARK: - Chat history storage
    private func saveCurrentChat() {
        guard let idx = chats.firstIndex(where: { $0.id == currentChatId }) else { return }
        let compact = messages.map { ChatMessageCodable(isUser: $0.isUser, text: $0.text) }
        var chat = chats[idx]
        chat.messages = compact
        if let firstUser = compact.first(where: { $0.isUser && !$0.text.isEmpty }) {
            chat.title = String(firstUser.text.prefix(28))
        }
        chats[idx] = chat
        persistChats()
        
        // Limit message history to prevent memory issues
        if messages.count > 50 {
            messages = Array(messages.suffix(50))
        }
    }
    
    private func newChat() {
        saveCurrentChat()
        let chat = Chat(id: UUID(), title: "New Chat", messages: [])
        chats.insert(chat, at: 0)
        currentChatId = chat.id
        messages = []
    }
    
    private func loadChat(_ id: UUID) {
        saveCurrentChat()
        currentChatId = id
        if let chat = chats.first(where: { $0.id == id }) {
            messages = chat.messages.map { ChatMessage(isUser: $0.isUser, text: $0.text, attachments: []) }
        }
    }
    
    private func deleteChat(_ id: UUID) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            chats.removeAll { $0.id == id }
            
            // If we deleted the current chat, switch to the first available chat
            if currentChatId == id {
                if let firstChat = chats.first {
                    currentChatId = firstChat.id
                    messages = firstChat.messages.map { ChatMessage(isUser: $0.isUser, text: $0.text, attachments: []) }
                } else {
                    // Create a new chat if no chats remain
                    newChat()
                }
            }
        }
        persistChats()
    }
    
    private func persistChats() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(chats) {
            UserDefaults.standard.set(data, forKey: "chats_store")
        }
    }
    
    private func restoreChats() {
        if let data = UserDefaults.standard.data(forKey: "chats_store"),
           let decoded = try? JSONDecoder().decode([Chat].self, from: data),
           !decoded.isEmpty {
            chats = decoded
            currentChatId = decoded.first!.id
            messages = decoded.first!.messages.map { ChatMessage(isUser: $0.isUser, text: $0.text, attachments: []) }
        } else {
            let initial = Chat(id: currentChatId, title: "New Chat", messages: [])
            chats = [initial]
        }
    }
}

struct MessagesListView: View {
    let messages: [ChatMessage]
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(messages) { msg in
                    MessageRowView(message: msg)
                        .frame(maxWidth: .infinity, alignment: msg.isUser ? .trailing : .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }
}

struct MessageRowView: View {
    let message: ChatMessage
    @State private var showingImagePreview = false
    @State private var previewImage: UIImage?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.isUser ? "You" : "Gemini")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
            ChatBubble(direction: message.isUser ? .right : .left) {
                VStack(alignment: .leading, spacing: 8) {
                    if !message.text.isEmpty {
                        Text(message.text)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(message.isUser ? Color.mint.opacity(0.25) : Color.gray.opacity(0.3))
                            .cornerRadius(10)
                    }
                    if !message.attachments.isEmpty {
                        AttachmentsRowView(
                            attachments: message.attachments,
                            onImageTap: { image in
                                previewImage = image
                                showingImagePreview = true
                            }
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showingImagePreview) {
            if let image = previewImage {
                ImagePreviewView(image: image)
            }
        }
    }
}

struct AttachmentsRowView: View {
    let attachments: [Attachment]
    let onImageTap: ((UIImage) -> Void)?
    
    init(attachments: [Attachment], onImageTap: ((UIImage) -> Void)? = nil) {
        self.attachments = attachments
        self.onImageTap = onImageTap
    }
    
    var body: some View {
        VStack(spacing: 8) {
            ForEach(attachments) { file in
                if file.mimeType.hasPrefix("image/"), let image = UIImage(data: file.data) {
                    // Display image attachment
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .cornerRadius(12)
                        .onTapGesture {
                            onImageTap?(image)
                        }
                } else {
                    // Display file attachment
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                        Text(file.filename)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(8)
                }
            }
        }
    }
}


struct BlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

// MARK: - Sidebar View
struct SidebarView: View {
    let chats: [Chat]
    let currentChatId: UUID
    let onNewChat: () -> Void
    let onLoadChat: (UUID) -> Void
    let onDeleteChat: (UUID) -> Void
    
    @State private var showingDeleteAlert = false
    @State private var chatToDelete: UUID?
    
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("History")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Button(action: onNewChat) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(.mint)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
                
                // Chat list
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(chats) { chat in
                            ChatRowView(
                                chat: chat,
                                isSelected: chat.id == currentChatId,
                                onTap: { onLoadChat(chat.id) },
                                onDelete: { 
                                    chatToDelete = chat.id
                                    showingDeleteAlert = true
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.regularMaterial)
        .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 350)
        .alert("Delete Chat", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let chatId = chatToDelete {
                    onDeleteChat(chatId)
                }
            }
        } message: {
            Text("Are you sure you want to delete this chat? This action cannot be undone.")
        }
    }
}

struct ChatRowView: View {
    let chat: Chat
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chat.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? .mint : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    Text("\(chat.messages.count) messages")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.mint)
                        .font(.system(size: 16))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? .mint.opacity(0.1) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? .mint.opacity(0.3) : .clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete Chat", systemImage: "trash")
            }
        }
    }
}

// MARK: - Chat Detail View
struct ChatDetailView: View {
    let messages: [ChatMessage]
    @Binding var text: String
    @Binding var isExpanded: Bool
    let isListening: Bool
    let isSending: Bool
    @Binding var pendingAttachments: [Attachment]
    @Binding var selectedPhotoItem: PhotosPickerItem?
    @Binding var showFileImporter: Bool
    let onStartListening: () -> Void
    let onStopListening: () -> Void
    let onSendMessage: () -> Void
    let onPreviewImage: (Attachment) -> UIImage?
    let onRemoveAttachment: (Attachment) -> Void
    
    @State private var showSearchMenu = false
    @State private var selectedSearchType = "Text-based"
    
    var body: some View {
        VStack(spacing: 0) {
            // Messages
            MessagesListView(messages: messages)
            
            Spacer()
            
            // Input area
            VStack(spacing: 16) {
                // Search menu
                if showSearchMenu {
                    SearchMenuView(
                        selectedSearchType: $selectedSearchType,
                        onDismiss: { showSearchMenu = false }
                    )
                }
                
                // Input field
                InputFieldView(
                    text: $text,
                    isExpanded: $isExpanded,
                    isListening: isListening,
                    isSending: isSending,
                    pendingAttachments: $pendingAttachments,
                    selectedPhotoItem: $selectedPhotoItem,
                    showFileImporter: $showFileImporter,
                    onStartListening: onStartListening,
                    onStopListening: onStopListening,
                    onSendMessage: onSendMessage,
                    onPreviewImage: onPreviewImage,
                    onRemoveAttachment: onRemoveAttachment,
                    onShowSearchMenu: { showSearchMenu.toggle() }
                )
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(.ultraThinMaterial)
    }
}

// MARK: - Search Menu View
struct SearchMenuView: View {
    @Binding var selectedSearchType: String
    let onDismiss: () -> Void
    
    private let searchTypes = ["Text-based", "Image generation"]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("🔍 Choose Search Type")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            
            Picker("Search Type", selection: $selectedSearchType) {
                ForEach(searchTypes, id: \.self) { type in
                    Text(type)
                        .tag(type)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedSearchType) { _ in
                // Auto-dismiss after selection
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onDismiss()
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.15),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    LinearGradient(
                        colors: [.mint.opacity(0.6), .cyan.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
        )
        .shadow(color: .black.opacity(0.1), radius: 20, x: 0, y: 10)
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.8))
    }
}


// MARK: - Input Field View
struct InputFieldView: View {
    @Binding var text: String
    @Binding var isExpanded: Bool
    let isListening: Bool
    let isSending: Bool
    @Binding var pendingAttachments: [Attachment]
    @Binding var selectedPhotoItem: PhotosPickerItem?
    @Binding var showFileImporter: Bool
    let onStartListening: () -> Void
    let onStopListening: () -> Void
    let onSendMessage: () -> Void
    let onPreviewImage: (Attachment) -> UIImage?
    let onRemoveAttachment: (Attachment) -> Void
    let onShowSearchMenu: () -> Void
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Thumbnail preview
            if let latestAttachment = pendingAttachments.last,
               let uiImage = onPreviewImage(latestAttachment) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.white.opacity(0.3), lineWidth: 1)
                    )
                    .offset(x: 16, y: -70)
                    .onTapGesture {
                        onRemoveAttachment(latestAttachment)
                    }
            }
            
            HStack(spacing: 12) {
                // Action buttons
                if isExpanded {
                    Menu {
                        Button { /* Camera */ } label: { 
                            Label("Camera", systemImage: "camera") 
                        }
                        Button { showFileImporter = true } label: { 
                            Label("Files", systemImage: "folder") 
                        }
                    } label: {
                Image(systemName: "paperclip.circle.fill")
                    .font(.title2)
                    .foregroundColor(.primary)
                    }
                    
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title2)
                            .foregroundColor(.primary)
                    }
                    
                    Button(action: onShowSearchMenu) {
                        Image(systemName: "magnifyingglass.circle.fill")
                            .font(.title2)
                            .foregroundColor(.mint)
                    }
                }
                
                // Text field
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text("Ask Anything...")
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)
                    }
                    
                    TextField("", text: $text, onEditingChanged: { editing in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isExpanded = editing
                        }
                    })
                    .textFieldStyle(.plain)
                    .foregroundColor(.primary)
                    .accentColor(.mint)
                    .disableAutocorrection(true)
                }
                
                // Mic button
                Button(action: {
                    if isListening {
                        onStopListening()
                    } else {
                        onStartListening()
                    }
                }) {
                    if isListening {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundColor(.red)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.title2)
                            .foregroundColor(.primary)
                    }
                }
                
                // Send button
                Button(action: onSendMessage) {
                    if isSending {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .mint))
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundColor(
                                text.isEmpty && pendingAttachments.isEmpty ? .secondary : .mint
                            )
                    }
                }
                .disabled(isSending || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 25)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 25)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.2),
                                        Color.white.opacity(0.1)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 25)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.4),
                                Color.white.opacity(0.2)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.1), radius: 15, x: 0, y: 8)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .preferredColorScheme(.dark)
    }
}
