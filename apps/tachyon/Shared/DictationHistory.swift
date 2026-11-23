import Foundation

/// How long dictated text is kept on this device.
enum HistoryRetention: String, CaseIterable {
    case never
    case day
    case week
    case month
    case forever

    var title: String {
        switch self {
        case .never: return "保存しない"
        case .day: return "24時間"
        case .week: return "1週間"
        case .month: return "30日間"
        case .forever: return "無期限"
        }
    }

    /// Entries older than this are dropped; nil keeps them all.
    var lifetime: TimeInterval? {
        switch self {
        case .never: return 0
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        case .forever: return nil
        }
    }
}

/// What was dictated, newest first, so text is never lost when a paste goes wrong.
///
/// Kept in a file only this user can read, on this device. Nothing is uploaded.
@MainActor
final class DictationHistory: ObservableObject {
    static let shared = DictationHistory()

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var date: Date
        var text: String
    }

    @Published private(set) var entries: [Entry] = []

    static let retentionKey = "dictationHistoryRetention"

    var retention: HistoryRetention {
        get { UserDefaults.standard.string(forKey: Self.retentionKey).flatMap(HistoryRetention.init) ?? .forever }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.retentionKey)
            prune()
        }
    }

    /// Even "forever" stops somewhere: the file is read and written whole.
    private static let maximumEntries = 5_000

    private let url: URL

    private init() {
        url = Settings.directory.appendingPathComponent("dictation-history.json")
        load()
        prune()
    }

    func add(_ text: String, at date: Date = Date()) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, retention != .never else { return }
        entries.insert(Entry(date: date, text: text), at: 0)
        if entries.count > Self.maximumEntries {
            entries.removeLast(entries.count - Self.maximumEntries)
        }
        save()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// Drops what is older than the chosen retention.
    func prune(now: Date = Date()) {
        guard let lifetime = retention.lifetime else { return }
        let kept = entries.filter { now.timeIntervalSince($0.date) < lifetime }
        guard kept.count != entries.count else { return }
        entries = kept
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        entries = (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        // What was said is private: readable by this user only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
