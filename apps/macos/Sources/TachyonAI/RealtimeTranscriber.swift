import Foundation

/// One push-to-talk dictation: issues a client secret through the Tachyon model gateway,
/// then streams audio to the OpenAI Realtime transcription session it describes.
@MainActor
final class RealtimeTranscriber {
    /// Text recognised so far (grows while speaking).
    var onPartial: ((String) -> Void)?

    enum TranscribeError: LocalizedError {
        case gateway(Int, String)
        case realtime(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .gateway(let status, let body): return "Gateway \(status): \(body)"
            case .realtime(let message): return "Realtime: \(message)"
            case .timeout: return "文字起こしがタイムアウトしました"
            }
        }
    }

    private let loadConfig: () async throws -> Config
    private let session = URLSession(configuration: .ephemeral)
    private var socket: URLSessionWebSocketTask?
    private var pending: [Data] = []
    private var isOpen = false
    private var sentBytes = 0
    private var partial = ""
    private var finalText: String?
    private var failure: Error?
    private var waiter: CheckedContinuation<Void, Never>?
    private let createdAt = Date()
    private var lastDeltaAt: Date?
    private var settledEarly = false
    private var returnedText = ""
    private var metrics = Metrics()

    /// Timings of one dictation, for tuning how early the text can be pasted.
    struct Metrics {
        var startedAt = Date()
        /// The connection was already open when the key went down.
        var wasWarm = false
        /// Whether the pasted text equals the server-confirmed one (ignoring outer whitespace).
        var matchedConfirmed: Bool?
        var openedAt: Date?
        var committedAt: Date?
        var firstDeltaAfterCommitAt: Date?
        var lastDeltaAt: Date?
        var confirmedAt: Date?
        var returnedAt: Date?
        var returnedLength = 0
        var returnedEarly = false
        /// Length of the server-confirmed transcript; nil if it never arrived.
        var confirmedLength: Int?
    }

    /// Called once the confirmed transcript has arrived (or been given up on).
    var onSettled: ((Metrics) -> Void)?

    /// `loadConfig` runs while audio is already being buffered, so it may refresh the token.
    init(loadConfig: @escaping () async throws -> Config) {
        self.loadConfig = loadConfig
    }

    /// Connects in the background. Audio appended before the socket opens is buffered.
    func start() {
        Task { await connect() }
    }

    /// Whether a connection opened ahead of time can still take a dictation. A dropped
    /// connection shows up as a failure; the age limit keeps well inside the server's
    /// 60-minute cap on a session.
    var isUsable: Bool {
        failure == nil && Date().timeIntervalSince(createdAt) < Self.maximumStandbyAge
    }

    private static let maximumStandbyAge: TimeInterval = 30 * 60

    /// Marks the moment the key went down (the connection may be older than that).
    func beginTurn() {
        metrics.startedAt = Date()
        metrics.wasWarm = isOpen
    }

    /// The text received so far, exactly as streamed.
    var streamedText: String { partial }

    func append(_ pcm: Data) {
        guard failure == nil else { return }
        if isOpen {
            send(pcm)
        } else {
            pending.append(pcm)
        }
    }

    /// Ends the turn and returns the transcript.
    ///
    /// Text streams in while the user is still speaking; the last words follow the
    /// release by about half a second, with the server's confirmation. If that
    /// confirmation is slow, the text is taken once it has stopped changing.
    func finish() async throws -> String {
        let deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self?.fail(TranscribeError.timeout)
        }
        defer { deadline.cancel() }

        while !isOpen, failure == nil {
            await wait()
        }
        if let failure {
            cancel()
            throw failure
        }

        // Committing an empty buffer is an error on the API side; nothing was said.
        guard sentBytes > 0 else {
            cancel()
            return ""
        }
        sendJSON(["type": "input_audio_buffer.commit"])
        let committedAt = Date()
        metrics.committedAt = committedAt

        let quiet = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard let self, self.finalText == nil, self.failure == nil else { return }
                let lastActivity = max(committedAt, self.lastDeltaAt ?? committedAt)
                if !self.partial.isEmpty, Date().timeIntervalSince(lastActivity) >= Self.quietWindow {
                    self.settledEarly = true
                    self.wake()
                    return
                }
            }
        }
        defer { quiet.cancel() }

        while finalText == nil, !settledEarly, failure == nil {
            await wait()
        }
        if let failure {
            cancel()
            throw failure
        }

        let returned = finalText ?? partial
        returnedText = returned
        metrics.returnedAt = Date()
        metrics.returnedLength = returned.count
        metrics.returnedEarly = finalText == nil
        settle()
        return returned
    }

    /// Safety net: if the confirmation is slow, take the text once it has stopped changing.
    private static let quietWindow: TimeInterval = 1.2

    /// Waits (briefly) for the confirmed transcript, reports the timings, then disconnects.
    private func settle() {
        Task {
            let giveUp = Date().addingTimeInterval(6)
            while finalText == nil, failure == nil, Date() < giveUp {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            metrics.confirmedLength = finalText?.count
            if let finalText {
                let trim = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
                metrics.matchedConfirmed = trim(finalText) == trim(returnedText)
            }
            onSettled?(metrics)
            cancel()
        }
    }

    func cancel() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        isOpen = false
        pending = []
        wake()
    }

    // MARK: - Connection

    private func connect() async {
        do {
            let config = try await loadConfig()
            let secret = try await issueClientSecret(config)
            var request = URLRequest(url: config.realtimeURL)
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            let socket = session.webSocketTask(with: request)
            self.socket = socket
            socket.resume()
            receive(on: socket)
        } catch {
            fail(error)
        }
    }

    private func issueClientSecret(_ config: Config) async throws -> String {
        var request = URLRequest(url: config.apiURL.appendingPathComponent("v1/ai/realtime/client-secret"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.operatorID, forHTTPHeaderField: "x-operator-id")
        // vad "off": the turn ends when the key is released, not on silence.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "mode": "whisper",
            "transcription": config.language,
            "vad": "off",
        ])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let secret = json["client_secret"] as? String else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw TranscribeError.gateway(status, body)
        }
        return secret
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === socket else { return }
                switch result {
                case .failure(let error):
                    self.fail(TranscribeError.realtime(error.localizedDescription))
                case .success(let message):
                    if case .string(let text) = message {
                        self.handle(text)
                    }
                    self.receive(on: socket)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }

        switch type {
        case "session.created":
            metrics.openedAt = Date()
            isOpen = true
            pending.forEach(send)
            pending = []
            wake()
        case "conversation.item.input_audio_transcription.delta":
            let now = Date()
            lastDeltaAt = now
            metrics.lastDeltaAt = now
            if metrics.committedAt != nil, metrics.firstDeltaAfterCommitAt == nil {
                metrics.firstDeltaAfterCommitAt = now
            }
            partial += event["delta"] as? String ?? ""
            onPartial?(partial)
        case "conversation.item.input_audio_transcription.completed":
            metrics.confirmedAt = Date()
            finalText = event["transcript"] as? String ?? partial
            wake()
        case "conversation.item.input_audio_transcription.failed", "error":
            let error = event["error"] as? [String: Any]
            fail(TranscribeError.realtime(error?["message"] as? String ?? type))
        default:
            break
        }
    }

    // MARK: - Sending

    private func send(_ pcm: Data) {
        sentBytes += pcm.count
        sendJSON(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, self.socket === socket else { return }
                self.fail(TranscribeError.realtime(error.localizedDescription))
            }
        }
    }

    // MARK: - Waiting

    private func fail(_ error: Error) {
        if failure == nil, finalText == nil {
            failure = error
        }
        wake()
    }

    private func wait() async {
        await withCheckedContinuation { waiter = $0 }
    }

    private func wake() {
        waiter?.resume()
        waiter = nil
    }
}
