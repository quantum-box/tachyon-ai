import Foundation

/// Client tools that let the agent work in a project's folder. The app runs them and
/// sends the result back; every path stays inside the folder.
enum WorkspaceTools {
    static let list = "workspace_list"
    static let read = "workspace_read"
    static let search = "workspace_search"
    static let write = "workspace_write"

    static let names: Set<String> = [list, read, search, write]

    static func instructions(folderName: String) -> String {
        """
        The user has opened their folder "\(folderName)" as this conversation's workspace. \
        Use the workspace_list, workspace_read, workspace_search and workspace_write tools to look at and change \
        its files. Paths are relative to the folder's root ("." is the root). Read a file before changing it, \
        and write whole files. The user may be asked before each write and may decline.
        """
    }

    static let definitions: [[String: Any]] = [
        [
            "name": list,
            "description": "List the files and folders in a folder of the workspace. Folders end with /. "
                + "Hidden entries and dependency folders (node_modules, .git, build output) are left out.",
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Folder to list, relative to the workspace root. Defaults to \".\"."],
                    "recursive": ["type": "boolean", "description": "Also list everything below it (up to 500 entries)."],
                ],
            ],
            "fire_and_forget": false,
        ],
        [
            "name": read,
            "description": "Read a text file of the workspace, with line numbers. Long files are cut; "
                + "use start_line to read further.",
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "File to read, relative to the workspace root."],
                    "start_line": ["type": "integer", "description": "First line to return (1-based). Defaults to 1."],
                ],
                "required": ["path"],
            ],
            "fire_and_forget": false,
        ],
        [
            "name": search,
            "description": "Find lines containing a piece of text (case-insensitive) in the workspace's text files. "
                + "Returns up to 200 matches as path:line: text.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Text to look for."],
                    "path": ["type": "string", "description": "Folder to search in, relative to the root. Defaults to \".\"."],
                ],
                "required": ["query"],
            ],
            "fire_and_forget": false,
        ],
        [
            "name": write,
            "description": "Create a text file in the workspace, or replace one with new content. "
                + "Missing folders are created. The user may be asked first and may decline.",
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "File to write, relative to the workspace root."],
                    "content": ["type": "string", "description": "The file's whole new content."],
                ],
                "required": ["path", "content"],
            ],
            "fire_and_forget": false,
            // Long enough for the user to answer the prompt.
            "timeout_seconds": 300,
        ],
    ]

    /// A write the agent asked for, shown to the user before it happens.
    struct WriteRequest {
        let path: String
        let content: String
        let exists: Bool
    }

    enum Failure: LocalizedError {
        case outsideWorkspace(String)
        case missingArgument(String)
        case notText(String)
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .outsideWorkspace(let path): return "\(path) is outside the workspace folder."
            case .missingArgument(let name): return "The \(name) argument is required."
            case .notText(let path): return "\(path) is not a UTF-8 text file."
            case .notFound(let path): return "\(path) does not exist."
            }
        }
    }

    private static let skipped: Set<String> = [
        "node_modules", ".git", ".build", "build", "dist", "target", "DerivedData", "Pods", ".next", "__pycache__",
    ]
    private static let maxReadCharacters = 60_000
    private static let maxListEntries = 500
    private static let maxMatches = 200
    private static let maxSearchedFileBytes = 2_000_000

    /// Runs one tool. `confirmWrite` asks the user and returns whether to go ahead.
    static func run(
        _ name: String, args: [String: Any], root: URL,
        confirmWrite: (WriteRequest) async -> Bool
    ) async -> (text: String, isError: Bool) {
        // The folder is a security-scoped bookmark: open it for the length of the call.
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        do {
            switch name {
            case list:
                return (try listFiles(root: root, path: args["path"] as? String ?? ".",
                                      recursive: args["recursive"] as? Bool ?? false), false)
            case read:
                let path = try string("path", in: args)
                let start = (args["start_line"] as? Int) ?? 1
                return (try readFile(root: root, path: path, startLine: start), false)
            case search:
                return (try searchFiles(root: root, query: try string("query", in: args),
                                        path: args["path"] as? String ?? "."), false)
            case write:
                let path = try string("path", in: args)
                let content = args["content"] as? String ?? ""
                let url = try resolve(path, in: root)
                let request = WriteRequest(
                    path: relative(url, to: root), content: content,
                    exists: FileManager.default.fileExists(atPath: url.path))
                guard await confirmWrite(request) else {
                    return ("The user declined to write \(request.path).", true)
                }
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: url, options: .atomic)
                return ("Wrote \(request.path) (\(content.utf8.count) bytes).", false)
            default:
                return ("Unknown tool \(name).", true)
            }
        } catch {
            return (error.localizedDescription, true)
        }
    }

    // MARK: - Paths

    private static func string(_ key: String, in args: [String: Any]) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty else { throw Failure.missingArgument(key) }
        return value
    }

    /// The file `path` names under `root`, refusing anything that leads out of it
    /// (`..`, absolute paths, symbolic links pointing elsewhere).
    static func resolve(_ path: String, in root: URL) throws -> URL {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : base.appendingPathComponent(trimmed.isEmpty ? "." : trimmed)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard resolved.path == base.path || resolved.path.hasPrefix(basePath) else {
            throw Failure.outsideWorkspace(path)
        }
        return resolved
    }

    /// `url`'s path under the root. Listed entries keep their own names (a symbolic link
    /// is not followed), so the root is matched both as given and with links resolved.
    private static func relative(_ url: URL, to root: URL) -> String {
        let path = url.standardizedFileURL.path
        let bases = [root.standardizedFileURL.path, root.standardizedFileURL.resolvingSymlinksInPath().path]
        for base in bases {
            if path == base { return "." }
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return url.lastPathComponent
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    // MARK: - Tools

    private static func listFiles(root: URL, path: String, recursive: Bool) throws -> String {
        let folder = try resolve(path, in: root)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw Failure.notFound(path) }
        var lines: [String] = []
        var truncated = false
        if recursive {
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            while let url = enumerator?.nextObject() as? URL {
                let directory = isDirectory(url)
                if directory, skipped.contains(url.lastPathComponent) {
                    enumerator?.skipDescendants()
                    continue
                }
                guard lines.count < maxListEntries else { truncated = true; break }
                lines.append(relative(url, to: root) + (directory ? "/" : ""))
            }
        } else {
            let entries = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let directory = isDirectory(url)
                if directory, skipped.contains(url.lastPathComponent) { continue }
                guard lines.count < maxListEntries else { truncated = true; break }
                lines.append(relative(url, to: root) + (directory ? "/" : ""))
            }
        }
        if lines.isEmpty { return "(empty)" }
        if truncated { lines.append("… (more entries left out)") }
        return lines.joined(separator: "\n")
    }

    private static func readFile(root: URL, path: String, startLine: Int) throws -> String {
        let url = try resolve(path, in: root)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.notFound(path) }
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw Failure.notText(path) }
        let lines = text.components(separatedBy: "\n")
        let first = max(1, startLine)
        guard first <= lines.count else { return "(the file has \(lines.count) lines)" }
        var output = ""
        var line = first
        while line <= lines.count {
            let next = "\(line)\t\(lines[line - 1])\n"
            if output.count + next.count > maxReadCharacters {
                output += "… (cut at line \(line - 1) of \(lines.count); read on with start_line \(line))"
                break
            }
            output += next
            line += 1
        }
        return output
    }

    private static func searchFiles(root: URL, query: String, path: String) throws -> String {
        let folder = try resolve(path, in: root)
        let needle = query.lowercased()
        var matches: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])
        search: while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if skipped.contains(url.lastPathComponent) { enumerator?.skipDescendants() }
                continue
            }
            guard (values?.fileSize ?? 0) <= maxSearchedFileBytes,
                  let data = try? Data(contentsOf: url), !data.contains(0),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated()
            where line.lowercased().contains(needle) {
                let shown = line.count > 300 ? String(line.prefix(300)) + "…" : line
                matches.append("\(relative(url, to: root)):\(index + 1): \(shown)")
                if matches.count >= maxMatches {
                    matches.append("… (more matches left out)")
                    break search
                }
            }
        }
        return matches.isEmpty ? "No matches." : matches.joined(separator: "\n")
    }
}
