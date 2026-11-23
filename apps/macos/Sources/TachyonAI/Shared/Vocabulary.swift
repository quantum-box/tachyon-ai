import Foundation

/// What the app knows about how the user speaks: words the transcription tends to get
/// wrong (registered by hand or picked up on its own), and free-form background that
/// helps guess others.
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

    /// A word the app registered on its own.
    struct Learned: Identifiable, Equatable {
        let id = UUID()
        /// What the transcription wrote before the user fixed it; empty for a word
        /// taken from typed text.
        var heard: String
        var written: String
        /// How many times the user made this same fix.
        var fixes: Int
        var lastSeen: Date

        /// One fix can be a change of mind ("テスト" to "Demo"); the same fix twice is a
        /// correction. Until then the word is only given to the model as one to expect.
        var replaces: Bool { !heard.isEmpty && fixes >= 2 }
    }

    /// Words given to the transcription model as ones to expect, and replacements
    /// applied to every transcript before it is pasted.
    @Published var entries: [Entry] {
        didSet { save() }
    }

    /// Words picked up automatically, most recently seen first.
    @Published private(set) var learned: [Learned] {
        didSet { saveLearned() }
    }

    /// Background (role, product names, jargon) given to the transcription model and
    /// the LLM cleanup as context.
    @Published var background: String {
        didSet { UserDefaults.standard.set(background, forKey: Self.backgroundKey) }
    }

    /// Learned words the user deleted, lowercased: they are not picked up again.
    private var dismissed: Set<String>
    /// What the last dictations pasted. Their spellings are the model's, not the user's.
    private var recentDictations: [String] = []

    private static let entriesKey = "vocabularyEntries"
    private static let learnedKey = "vocabularyLearned"
    private static let dismissedKey = "vocabularyDismissed"
    private static let backgroundKey = "userBackground"
    private static let maximumLearned = 200
    private static let maximumDismissed = 500
    /// The transcription model takes this many keywords.
    private static let maximumKeywords = 100

    private init() {
        let defaults = UserDefaults.standard
        let stored = defaults.array(forKey: Self.entriesKey) as? [[String]] ?? []
        entries = stored.compactMap { pair in
            pair.count == 2 ? Entry(heard: pair[0], written: pair[1]) : nil
        }
        let learned = defaults.array(forKey: Self.learnedKey) as? [[String: Any]] ?? []
        self.learned = learned.compactMap { item in
            guard let written = item["written"] as? String, !written.isEmpty else { return nil }
            return Learned(
                heard: item["heard"] as? String ?? "",
                written: written,
                fixes: item["fixes"] as? Int ?? 0,
                lastSeen: Date(timeIntervalSince1970: item["lastSeen"] as? Double ?? 0))
        }
        dismissed = Set(defaults.stringArray(forKey: Self.dismissedKey) ?? [])
        background = defaults.string(forKey: Self.backgroundKey) ?? ""
    }

    private func save() {
        UserDefaults.standard.set(entries.map { [$0.heard, $0.written] }, forKey: Self.entriesKey)
    }

    private func saveLearned() {
        let items = learned.map { item -> [String: Any] in
            ["heard": item.heard, "written": item.written, "fixes": item.fixes,
             "lastSeen": item.lastSeen.timeIntervalSince1970]
        }
        UserDefaults.standard.set(items, forKey: Self.learnedKey)
    }

    struct Replacement {
        var heard: String
        var written: String
        /// Replace `heard` only where it stands as a word of its own. A learned fix was
        /// made to a whole word and says nothing about the same letters inside another:
        /// "Aws" to "AWS" must leave "draws" alone. The user's own entries match anywhere,
        /// as they always have.
        var wholeWord = false
    }

    /// Entries that can actually be applied (both sides filled in).
    var replacements: [Replacement] {
        let manual = entries.compactMap { entry -> Replacement? in
            let heard = entry.heard.trimmingCharacters(in: .whitespaces)
            let written = entry.written.trimmingCharacters(in: .whitespaces)
            return heard.isEmpty || written.isEmpty ? nil : Replacement(heard: heard, written: written)
        }
        // The user's own entry for a word wins over a learned one.
        let taken = Set(manual.map { $0.heard.lowercased() })
        let automatic = learned
            .filter { $0.replaces && !taken.contains($0.heard.lowercased()) }
            .map { Replacement(heard: $0.heard, written: $0.written, wholeWord: true) }
        return manual + automatic
    }

    /// Spellings the transcription model is told to expect, so it writes them itself.
    /// An entry needs no "heard" side for this. The user's own entries come first, then
    /// names in the background, then learned words from the most recent; the model's
    /// limit cuts off the oldest learned ones.
    var keywords: [String] {
        var seen = Set<String>()
        let candidates = entries.map { $0.written.trimmingCharacters(in: .whitespaces) }
            + TermLearning.terms(in: background)
            + learned.map(\.written)
        return Array(candidates
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(Self.maximumKeywords))
    }

    /// Rewrites every registered word. Longer words go first, so "タキオンフィールド"
    /// is not broken up by an entry for "タキオン".
    func apply(to text: String) -> String {
        Self.apply(replacements, to: text)
    }

    nonisolated static func apply(_ replacements: [Replacement], to text: String) -> String {
        var result = text
        for item in replacements.sorted(by: { $0.heard.count > $1.heard.count }) {
            result = item.wholeWord
                ? TermLearning.replacingWord(item.heard, with: item.written, in: result)
                : result.replacingOccurrences(of: item.heard, with: item.written, options: .caseInsensitive)
        }
        return result
    }

    // MARK: - Learning

    /// Remembers what a dictation produced, so its spellings are not taken for the user's.
    func noteDictated(_ text: String) {
        guard !text.isEmpty else { return }
        recentDictations = Array((recentDictations + [text.lowercased()]).suffix(5))
    }

    /// Picks up the names in text the user typed.
    func learn(fromTyped text: String) {
        guard Preferences.autoLearnTerms else { return }
        for term in TermLearning.terms(in: text) {
            // A word that a dictation just wrote may be in this text because it was
            // dictated: that spelling is the model's, and not known to be right.
            let lowered = term.lowercased()
            guard !recentDictations.contains(where: { $0.contains(lowered) }) else { continue }
            record(heard: "", written: term)
        }
    }

    /// Picks up a word the user rewrote after a dictation was pasted.
    func learn(_ corrections: [TermLearning.Correction]) {
        guard Preferences.autoLearnTerms else { return }
        for correction in corrections {
            record(heard: correction.heard, written: correction.written)
        }
    }

    /// Deletes a learned word for good.
    func forget(_ item: Learned) {
        learned.removeAll { $0.id == item.id }
        dismissed.insert(item.written.lowercased())
        if dismissed.count > Self.maximumDismissed {
            dismissed.removeFirst()
        }
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedKey)
    }

    private func record(heard: String, written: String) {
        let key = written.lowercased()
        guard !dismissed.contains(key),
              !entries.contains(where: { $0.written.trimmingCharacters(in: .whitespaces).lowercased() == key })
        else { return }

        var items = learned
        var item = Learned(heard: heard, written: written, fixes: heard.isEmpty ? 0 : 1, lastSeen: Date())
        if let index = items.firstIndex(where: { $0.written.lowercased() == key }) {
            let known = items.remove(at: index)
            if heard.isEmpty {
                // Seen again in typed text: what was learned from a fix stays.
                item.heard = known.heard
                item.fixes = known.fixes
            } else if known.heard.caseInsensitiveCompare(heard) == .orderedSame {
                item.fixes = known.fixes + 1
            }
        }
        items.insert(item, at: 0)
        learned = Array(items.prefix(Self.maximumLearned))
    }
}
