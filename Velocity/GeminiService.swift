import Foundation

final class GeminiService {
    enum ServiceError: Error {
        case missingApiKey
        case badResponse
        case decodingFailed
        case requestFailed(statusCode: Int)
    }

    private let session: URLSession
    private let model: String

    init(session: URLSession = .shared, model: String = "gemini-1.5-flash") {
        self.session = session
        self.model = model
    }

    func generateResponse(for userText: String, attachments: [Attachment] = [], history: [ChatMessage] = []) async throws -> String {
        let apiKey = (Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String) ?? ""
        guard apiKey.isEmpty == false else { throw ServiceError.missingApiKey }

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw ServiceError.badResponse }

        var parts: [[String: Any]] = []

        // Include a compact history summary to give minimal context (optional)
        if history.isEmpty == false {
            let joined = history.map { ($0.isUser ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n")
            parts.append([
                "text": "Context (most recent first):\n\(joined.suffix(4000))"
            ])
        }

        // User text
        if userText.isEmpty == false {
            parts.append(["text": userText])
        }

        // Inline attachments
        for file in attachments {
            let b64 = file.data.base64EncodedString()
            parts.append([
                "inlineData": [
                    "mimeType": file.mimeType,
                    "data": b64
                ]
            ])
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": parts
                ]
            ]
        ]

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

        // Parse candidates[0].content.parts[].text
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


