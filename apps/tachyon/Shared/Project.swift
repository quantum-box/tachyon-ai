import Foundation

/// A group of conversations that share instructions and, optionally, a folder on this
/// device that the agent works in. Projects live on this device only; a conversation
/// remembers its project through the session's metadata on the server.
struct Project: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    /// Sent with every message of the project's conversations.
    var instructions = ""
    /// The workspace folder, as a security-scoped bookmark so the sandboxed app can
    /// open it again after a relaunch.
    var folderBookmark: Data?
    /// Where the folder was when it was chosen, for display.
    var folderPath: String?
    /// Lets the agent write files without asking each time.
    var allowsWritesWithoutAsking = false

    var folderName: String? {
        folderPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// The folder the bookmark points to now (it follows moves and renames).
    func resolveFolder() -> URL? {
        guard let folderBookmark else { return nil }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        return try? URL(resolvingBookmarkData: folderBookmark, options: options, relativeTo: nil,
                        bookmarkDataIsStale: &stale)
    }

    mutating func setFolder(_ url: URL) throws {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        folderBookmark = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        folderPath = url.path
    }

    mutating func clearFolder() {
        folderBookmark = nil
        folderPath = nil
    }

    /// What the agent is told about the project on every message.
    var agentInstructions: String {
        var parts: [String] = []
        let own = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty {
            parts.append("This conversation belongs to the user's project \"\(name)\". The user's instructions for it:\n\(own)")
        }
        if let folderName {
            parts.append(WorkspaceTools.instructions(folderName: folderName))
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Projects saved in `Application Support/TachyonAI/projects.json`.
enum ProjectStore {
    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("TachyonAI/projects.json")
    }

    static func load() -> [Project] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Project].self, from: data)) ?? []
    }

    static func save(_ projects: [Project]) {
        guard let fileURL, let data = try? JSONEncoder().encode(projects) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
