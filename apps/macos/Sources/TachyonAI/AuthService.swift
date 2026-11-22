import AppKit
import AuthenticationServices
import CryptoKit

/// Signs the user in to Tachyon in a system login window and keeps the token fresh.
///
/// Same flow as `tachyon auth login`: Cognito authorization code + PKCE, with the redirect
/// received on a loopback port.
@MainActor
final class AuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    struct Credentials: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var operatorID: String?
    }

    enum AuthError: LocalizedError {
        case notLoggedIn
        case loginInProgress
        case cancelled
        case timedOut
        case portsBusy
        case noTenant
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn: return "ログインが必要です (メニューバー > ログイン)"
            case .loginInProgress: return "ログイン中です"
            case .cancelled: return "ログインをキャンセルしました"
            case .timedOut: return "ログインがタイムアウトしました"
            case .portsBusy: return "ログイン用のポートが使用中です (tachyon auth login を終了)"
            case .noTenant: return "利用できるテナントがありません"
            case .server(let message): return "ログイン失敗: \(message)"
            }
        }
    }

    private(set) var credentials: Credentials?
    private var webSession: ASWebAuthenticationSession?
    private var windowClosedByUser = false
    private var refreshTask: Task<Credentials, Error>?

    var isLoggedIn: Bool { credentials != nil }
    var isLoggingIn: Bool { webSession != nil }

    override init() {
        super.init()
        credentials = Self.loadStored()
    }

    // MARK: - Config for a dictation

    /// Refreshes the access token first when it is about to expire.
    func config() async throws -> Config {
        let settings = Settings.load()
        let token: String
        var operatorID = settings.operatorID

        if let apiKey = settings.apiKey {
            token = apiKey
        } else {
            let current = try await freshCredentials(settings)
            token = current.accessToken
            operatorID = operatorID ?? current.operatorID
        }
        guard let operatorID else { throw AuthError.noTenant }
        return Config(apiURL: settings.apiURL, realtimeURL: settings.realtimeURL,
                      bearerToken: token, operatorID: operatorID, language: settings.language,
                      chatModel: settings.chatModel, cleanupModel: settings.cleanupModel)
    }

    private func freshCredentials(_ settings: Settings) async throws -> Credentials {
        guard let current = credentials else { throw AuthError.notLoggedIn }
        guard let expiresAt = current.expiresAt, expiresAt.timeIntervalSinceNow < 60 else {
            return current
        }
        if let refreshTask { return try await refreshTask.value }

        let task = Task { try await self.refresh(current, settings) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func refresh(_ current: Credentials, _ settings: Settings) async throws -> Credentials {
        guard let refreshToken = current.refreshToken else {
            logout()
            throw AuthError.notLoggedIn
        }
        do {
            let tokens = try await requestTokens(settings, [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ])
            var updated = current
            updated.accessToken = tokens.access_token
            // Cognito does not return a new refresh token on refresh.
            updated.refreshToken = tokens.refresh_token ?? refreshToken
            updated.expiresAt = tokens.expires_in.map { Date().addingTimeInterval($0) }
            store(updated)
            return updated
        } catch AuthError.server {
            // The refresh token itself was rejected: a new login is the only way forward.
            logout()
            throw AuthError.notLoggedIn
        }
    }

    // MARK: - Login

    func login() async throws {
        guard webSession == nil else { throw AuthError.loginInProgress }
        let settings = Settings.load()

        let state = Self.randomURLSafe(bytes: 16)
        let verifier = Self.randomURLSafe(bytes: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        guard let callback = LoopbackCallback() else { throw AuthError.portsBusy }
        defer { callback.stop() }
        let redirectURI = callback.redirectURI

        var authorize = URLComponents(
            url: settings.cognitoDomain.appendingPathComponent("oauth2/authorize"),
            resolvingAgainstBaseURL: false)!
        authorize.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: settings.cognitoClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email aws.cognito.signin.user.admin"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        // The redirect goes to the loopback listener, not to a custom URL scheme, so the
        // window never completes on its own: it is closed here once the code arrives.
        windowClosedByUser = false
        let webSession = ASWebAuthenticationSession(url: authorize.url!, callbackURLScheme: nil) { [weak self] _, _ in
            Task { @MainActor in self?.windowClosedByUser = true }
        }
        webSession.presentationContextProvider = self
        self.webSession = webSession
        defer {
            webSession.cancel()
            self.webSession = nil
        }

        NSApp.activate(ignoringOtherApps: true)
        guard webSession.start() else { throw AuthError.server("ログイン画面を開けませんでした") }

        let code = try await waitForCode(callback, state: state)
        let tokens = try await requestTokens(settings, [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ])
        let operatorID = try? await defaultOperator(settings, accessToken: tokens.access_token)
        store(Credentials(
            accessToken: tokens.access_token,
            refreshToken: tokens.refresh_token,
            expiresAt: tokens.expires_in.map { Date().addingTimeInterval($0) },
            operatorID: operatorID))
    }

    func logout() {
        credentials = nil
        try? FileManager.default.removeItem(at: Self.storeURL)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? ASPresentationAnchor() }
    }

    private func waitForCode(_ callback: LoopbackCallback, state: String) async throws -> String {
        let query = try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { try await callback.waitForCallback(state: state) }
            // Ends the wait when the user closes the window or takes too long.
            group.addTask { @MainActor in
                let deadline = Date().addingTimeInterval(300)
                while Date() < deadline {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    if self.windowClosedByUser { throw AuthError.cancelled }
                }
                throw AuthError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? [:]
        }
        guard let code = query["code"] else {
            throw AuthError.server(query["error_description"] ?? query["error"] ?? "no code")
        }
        return code
    }

    // MARK: - HTTP

    private struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: TimeInterval?
    }

    private func requestTokens(_ settings: Settings, _ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: settings.cognitoDomain.appendingPathComponent("oauth2/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = fields
        form["client_id"] = settings.cognitoClientID
        request.httpBody = Data(form.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw AuthError.server(json?["error"] as? String ?? "token endpoint")
        }
        return tokens
    }

    /// The first tenant the user belongs to (same default as the CLI).
    private func defaultOperator(_ settings: Settings, accessToken: String) async throws -> String {
        var request = URLRequest(url: settings.apiURL.appendingPathComponent("v1/auth/operators/by-user"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let operators = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let id = operators.first?["id"] as? String else { throw AuthError.noTenant }
        return id
    }

    // MARK: - Storage

    private static var storeURL: URL {
        Settings.directory.appendingPathComponent("credentials.json")
    }

    private static func loadStored() -> Credentials? {
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    /// Owner-only file, like the CLI's profile files.
    private func store(_ new: Credentials) {
        credentials = new
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: Settings.directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(new)
            fileManager.createFile(atPath: Self.storeURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            try data.write(to: Self.storeURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.storeURL.path)
        } catch {
            NSLog("TachyonAI: could not save credentials: %@", error.localizedDescription)
        }
    }

    // MARK: - Encoding

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
