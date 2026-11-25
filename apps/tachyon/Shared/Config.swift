import Foundation

/// Everything one dictation needs to reach the gateway.
struct Config {
    var apiURL: URL
    var realtimeURL: URL
    var bearerToken: String
    var operatorID: String
    var language: String
    var chatModel: String
    var cleanupModel: String
}

/// Endpoints and optional overrides from
/// `~/Library/Application Support/TachyonAI/config.json`.
struct Settings {
    var apiURL = URL(string: "https://api.n1.tachy.one")!
    var realtimeURL = URL(string: "wss://api.openai.com/v1/realtime")!
    var cognitoDomain = URL(string: "https://auth-pool.n1.tachy.one")!
    /// The Tachyon web app, opened in the chat window's side pane.
    var webURL = URL(string: "https://app.n1.tachy.one")!
    /// tachyon-cli-client: a public OAuth client (PKCE, no secret).
    var cognitoClientID = "4101nun74fvfusnlsanc00urke"
    var language = "ja"
    /// Model the dictation session is switched to once connected; it must take
    /// keywords for the vocabulary to reach it. Empty keeps the gateway's own.
    var transcriptionModel = "gpt-live-transcribe"
    /// Model for the agent chat (the web app's default).
    var chatModel = "anthropic/claude-sonnet-5"
    /// Small, fast model for tidying dictated text.
    var cleanupModel = "anthropic/claude-haiku-4.5"
    /// Overrides the tenant chosen at login.
    var operatorID: String?
    /// When set, used instead of the signed-in user's token.
    var apiKey: String?

    private struct File: Decodable {
        var apiURL: String?
        var realtimeURL: String?
        var cognitoDomain: String?
        var webUrl: String?
        var cognitoClientId: String?
        var language: String?
        var transcriptionModel: String?
        var chatModel: String?
        var cleanupModel: String?
        var operatorId: String?
        var apiKey: String?
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TachyonAI")
    }

    /// Read on every use so edits apply without a restart.
    static func load() -> Settings {
        var settings = Settings()
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return settings
        }
        if let url = file.apiURL.flatMap(URL.init(string:)) { settings.apiURL = url }
        if let url = file.realtimeURL.flatMap(URL.init(string:)) { settings.realtimeURL = url }
        if let url = file.cognitoDomain.flatMap(URL.init(string:)) { settings.cognitoDomain = url }
        if let url = file.webUrl.flatMap(URL.init(string:)) { settings.webURL = url }
        if let id = file.cognitoClientId, !id.isEmpty { settings.cognitoClientID = id }
        if let language = file.language, !language.isEmpty { settings.language = language }
        if let model = file.transcriptionModel { settings.transcriptionModel = model }
        if let model = file.chatModel, !model.isEmpty { settings.chatModel = model }
        if let model = file.cleanupModel, !model.isEmpty { settings.cleanupModel = model }
        if let id = file.operatorId, !id.isEmpty { settings.operatorID = id }
        if let key = file.apiKey, !key.isEmpty { settings.apiKey = key }
        return settings
    }
}
