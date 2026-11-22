import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file sent along with a message.
struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let filename: String
    /// A MIME type the agent API accepts.
    let contentType: String
    let data: Data

    var isImage: Bool { contentType.hasPrefix("image/") }
}

enum AttachmentError: LocalizedError {
    case unsupported(String)
    case unreadable(String)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            return "「\(name)」は添付できません (画像とテキスト形式のファイルに対応しています)"
        case .unreadable(let name):
            return "「\(name)」を読み込めませんでした"
        case .tooLarge:
            return "添付の合計が大きすぎます (合計 約3MB まで)"
        }
    }
}

/// Turns files and photos into attachments the agent API accepts.
///
/// The API takes images (JPEG, PNG, GIF, WebP) and text documents, inline as base64,
/// in a request of at most 5 MB. Photos are therefore scaled down and re-encoded.
enum AttachmentLoader {
    /// Base64 adds a third, and the request also carries the message itself.
    static let maximumTotalBytes = 3_400_000

    /// Images at or under this size, already in an accepted format, are sent untouched.
    private static let imagePassThroughBytes = 1_200_000
    private static let imageMaximumPixels = 2048
    private static let acceptedImageTypes: [UTType: String] = [
        .jpeg: "image/jpeg", .png: "image/png", .gif: "image/gif", .webP: "image/webp",
    ]

    static func load(url: URL) throws -> Attachment {
        // Files picked through the system picker are only readable inside this scope.
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { throw AttachmentError.unreadable(name) }
        let type = UTType(filenameExtension: url.pathExtension)

        if type?.conforms(to: .image) == true {
            return try image(data, name: name, type: type)
        }
        return try text(data, name: name, type: type)
    }

    /// A photo or pasted image, with no file behind it.
    static func load(imageData: Data, name: String) throws -> Attachment {
        try image(imageData, name: name, type: nil)
    }

    private static func image(_ data: Data, name: String, type: UTType?) throws -> Attachment {
        if let type, let mime = acceptedImageTypes[type], data.count <= imagePassThroughBytes {
            return Attachment(filename: name, contentType: mime, data: data)
        }
        // Anything else (HEIC, TIFF, large photos) becomes a JPEG of a sensible size.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: imageMaximumPixels,
              ] as CFDictionary) else {
            throw AttachmentError.unreadable(name)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AttachmentError.unreadable(name)
        }
        CGImageDestinationAddImage(
            destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AttachmentError.unreadable(name) }

        let base = (name as NSString).deletingPathExtension
        return Attachment(filename: "\(base).jpg", contentType: "image/jpeg", data: output as Data)
    }

    private static func text(_ data: Data, name: String, type: UTType?) throws -> Attachment {
        // Source code, logs and config files are all just text to the agent. Anything
        // that is not valid UTF-8 text (PDF, Office documents, archives) is not accepted.
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw AttachmentError.unsupported(name)
        }
        return Attachment(filename: name, contentType: textMIME(for: type), data: data)
    }

    private static func textMIME(for type: UTType?) -> String {
        guard let type else { return "text/plain" }
        if type.conforms(to: .commaSeparatedText) { return "text/csv" }
        if type.conforms(to: .html) { return "text/html" }
        if type.conforms(to: .json) { return "application/json" }
        if type.conforms(to: .xml) { return "application/xml" }
        if type.conforms(to: .yaml) { return "application/x-yaml" }
        if type.preferredFilenameExtension == "md" { return "text/markdown" }
        return "text/plain"
    }
}

/// Tokens and cost of one reply, or of a whole conversation.
struct TokenUsage: Equatable {
    var promptTokens = 0
    var completionTokens = 0
    var totalTokens = 0
    /// US dollars, when the API reports a price.
    var cost: Double?

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            promptTokens: lhs.promptTokens + rhs.promptTokens,
            completionTokens: lhs.completionTokens + rhs.completionTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens,
            cost: lhs.cost == nil && rhs.cost == nil ? nil : (lhs.cost ?? 0) + (rhs.cost ?? 0))
    }

    /// For example "4,630 トークン · $0.0185".
    var summary: String {
        let tokens = "\(totalTokens.formatted()) トークン"
        guard let cost else { return tokens }
        // Single replies cost fractions of a cent, so small amounts keep four decimals.
        return tokens + " · $" + String(format: cost < 1 ? "%.4f" : "%.2f", cost)
    }
}
