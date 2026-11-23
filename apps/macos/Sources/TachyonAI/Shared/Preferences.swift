import Foundation

/// How hard a reasoning model thinks before answering.
enum ReasoningEffort: String, CaseIterable {
    /// Leave it to the model's own default (nothing is sent).
    case standard
    case low
    case medium
    case high

    var title: String {
        switch self {
        case .standard: return "標準"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    /// The value the API expects, or nil to omit the field.
    var apiValue: String? {
        self == .standard ? nil : rawValue
    }

    /// The API applies the setting to OpenAI's gpt-5 and gpt-6 families only;
    /// every other model ignores it.
    static func isSupported(by model: String) -> Bool {
        model.hasPrefix("openai/gpt-5") || model.hasPrefix("openai/gpt-6")
            || model.hasPrefix("openai:gpt-5") || model.hasPrefix("openai:gpt-6")
    }
}

/// User-toggled options kept in UserDefaults.
enum Preferences {
    /// The chat model picked in the composer; nil means the configured default.
    static var chatModel: String? {
        get { UserDefaults.standard.string(forKey: "chatModel") }
        set { UserDefaults.standard.set(newValue, forKey: "chatModel") }
    }

    static var reasoningEffort: ReasoningEffort {
        get { UserDefaults.standard.string(forKey: "reasoningEffort").flatMap(ReasoningEffort.init) ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "reasoningEffort") }
    }

    /// Models shown in the chat's model menu; nil means the default (the GPT-6 family).
    static var enabledModels: Set<String>? {
        get { (UserDefaults.standard.array(forKey: "enabledModels") as? [String]).map(Set.init) }
        set { UserDefaults.standard.set(newValue.map(Array.init), forKey: "enabledModels") }
    }

    /// The chat window's magnification; 1 is 100%.
    static var zoom: Double {
        get { UserDefaults.standard.object(forKey: "zoom") as? Double ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "zoom") }
    }

    /// The conversation that was open, reopened at the next launch.
    static var lastSessionID: String? {
        get { UserDefaults.standard.string(forKey: "lastSessionID") }
        set { UserDefaults.standard.set(newValue, forKey: "lastSessionID") }
    }

    /// Alpha: type the transcript into the app while speaking, instead of pasting it
    /// all at once after the key is released. Off unless turned on.
    static var liveInsert: Bool {
        get { UserDefaults.standard.object(forKey: liveInsertKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: liveInsertKey) }
    }

    static let liveInsertKey = "liveInsert"

    /// Play a short sound when recording starts and when the key is released. On unless turned off.
    static var dictationSounds: Bool {
        get { UserDefaults.standard.object(forKey: dictationSoundsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: dictationSoundsKey) }
    }

    static let dictationSoundsKey = "dictationSounds"

    /// Tokens and cost of every reply received in this app, until reset.
    static var totalUsage: TokenUsage {
        get {
            let defaults = UserDefaults.standard
            return TokenUsage(
                promptTokens: defaults.integer(forKey: "usagePromptTokens"),
                completionTokens: defaults.integer(forKey: "usageCompletionTokens"),
                totalTokens: defaults.integer(forKey: "usageTotalTokens"),
                cost: defaults.object(forKey: "usageCost") as? Double)
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.promptTokens, forKey: "usagePromptTokens")
            defaults.set(newValue.completionTokens, forKey: "usageCompletionTokens")
            defaults.set(newValue.totalTokens, forKey: "usageTotalTokens")
            defaults.set(newValue.cost, forKey: "usageCost")
        }
    }

    /// How dictated text is tidied before pasting. Fast (in-app) unless changed.
    static var cleanupMode: CleanupMode {
        get { UserDefaults.standard.string(forKey: cleanupModeKey).flatMap(CleanupMode.init) ?? .fast }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: cleanupModeKey) }
    }

    static let cleanupModeKey = "cleanupMode"
}
