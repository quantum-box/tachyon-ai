import Foundation

/// What the user has told the app about how they speak: words the transcription
/// tends to get wrong, and free-form background that helps guess others.
@MainActor
final class Vocabulary: ObservableObject {
    static let shared = Vocabulary()

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        /// How the transcription writes the word.
        var heard: String
        /// How it should be written.
        var written: String
    }

    /// Replacements applied to every transcript before it is pasted.
    @Published var entries: [Entry] {
        didSet { save() }
    }

    /// Background (role, product names, jargon) given to the LLM cleanup as context.
    @Published var background: String {
        didSet { UserDefaults.standard.set(background, forKey: Self.backgroundKey) }
    }

    private static let entriesKey = "vocabularyEntries"
    private static let backgroundKey = "userBackground"

    private init() {
        let stored = UserDefaults.standard.array(forKey: Self.entriesKey) as? [[String]] ?? []
        entries = stored.compactMap { pair in
            pair.count == 2 ? Entry(heard: pair[0], written: pair[1]) : nil
        }
        background = UserDefaults.standard.string(forKey: Self.backgroundKey) ?? ""
    }

    private func save() {
        UserDefaults.standard.set(entries.map { [$0.heard, $0.written] }, forKey: Self.entriesKey)
    }

    /// Entries that can actually be applied (both sides filled in).
    var replacements: [(heard: String, written: String)] {
        entries.compactMap { entry in
            let heard = entry.heard.trimmingCharacters(in: .whitespaces)
            let written = entry.written.trimmingCharacters(in: .whitespaces)
            return heard.isEmpty || written.isEmpty ? nil : (heard, written)
        }
    }

    /// Rewrites every registered word. Longer words go first, so "タキオンフィールド"
    /// is not broken up by an entry for "タキオン".
    func apply(to text: String) -> String {
        Self.apply(replacements, to: text)
    }

    nonisolated static func apply(_ replacements: [(heard: String, written: String)], to text: String) -> String {
        var result = text
        for (heard, written) in replacements.sorted(by: { $0.heard.count > $1.heard.count }) {
            result = result.replacingOccurrences(of: heard, with: written, options: .caseInsensitive)
        }
        return result
    }
}
