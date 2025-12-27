import Foundation
import UIKit

struct GalleryEntry: Identifiable, Codable {
    struct Metadata: Codable {
        let prompt: String
        let negativePrompt: String
        let modelId: String
        let modelName: String
        let steps: Int
        let guidance: Float
        let sampler: String
        let seed: UInt32
        let upscalerId: String?
        let upscalerName: String?
        let timestamp: Date
    }
    
    let id: UUID
    let imageFilename: String
    let thumbnailFilename: String
    let metadata: Metadata
}

final class GalleryStore {
    static let shared = GalleryStore()
    static let galleryUpdatedNotification = Notification.Name("GalleryUpdatedNotification")
    
    private init() {}
    
    // Directory layout: Documents/Gallery/{images, thumbs, metadata.json}
    private var galleryRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Gallery", isDirectory: true)
    }
    private var imagesDir: URL { galleryRoot.appendingPathComponent("images", isDirectory: true) }
    private var thumbsDir: URL { galleryRoot.appendingPathComponent("thumbs", isDirectory: true) }
    private var metadataURL: URL { galleryRoot.appendingPathComponent("metadata.json") }
    
    private func ensureDirs() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: galleryRoot.path) {
            try fm.createDirectory(at: galleryRoot, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: imagesDir.path) {
            try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: thumbsDir.path) {
            try fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        }
    }
    
    // Load all entries (most recent first)
    func loadAll() throws -> [GalleryEntry] {
        try ensureDirs()
        let data = (try? Data(contentsOf: metadataURL)) ?? Data()
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601OrSecondsSince1970
        return try decoder.decode([GalleryEntry].self, from: data).sorted { $0.metadata.timestamp > $1.metadata.timestamp }
    }
    
    // Save one image + metadata
    func save(image: UIImage, metadata: GalleryEntry.Metadata) async throws {
        try ensureDirs()
        let id = UUID()
        let imageName = "img_\(id.uuidString).jpg"
        let thumbName = "thumb_\(id.uuidString).jpg"
        let imageURL = imagesDir.appendingPathComponent(imageName)
        let thumbURL = thumbsDir.appendingPathComponent(thumbName)
        
        // Encode image
        guard let data = image.jpegData(compressionQuality: 0.92) else {
            throw NSError(domain: "GalleryStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode JPEG"])
        }
        try data.write(to: imageURL, options: .atomic)
        
        // Make thumbnail
        let thumb = makeThumbnail(image)
        if let tdata = thumb.jpegData(compressionQuality: 0.85) {
            try tdata.write(to: thumbURL, options: .atomic)
        }
        
        // Append metadata entry
        var entries = (try? loadAll()) ?? []
        let entry = GalleryEntry(id: id, imageFilename: imageName, thumbnailFilename: thumbName, metadata: metadata)
        entries.insert(entry, at: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601OrSecondsSince1970
        let metaData = try encoder.encode(entries)
        try metaData.write(to: metadataURL, options: .atomic)
        
        NotificationCenter.default.post(name: Self.galleryUpdatedNotification, object: nil)
    }
    
    // Helper: thumbnail generation (fit to 200x200)
    private func makeThumbnail(_ image: UIImage) -> UIImage {
        let target = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

// MARK: - JSONEncoder/Decoder date helpers
private extension JSONEncoder.DateEncodingStrategy {
    static var iso8601OrSecondsSince1970: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let iso = ISO8601DateFormatter()
            try container.encode(iso.string(from: date))
        }
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static var iso8601OrSecondsSince1970: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            let iso = ISO8601DateFormatter()
            if let d = iso.date(from: s) { return d }
            if let seconds = TimeInterval(s) { return Date(timeIntervalSince1970: seconds) }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format")
        }
    }
}
