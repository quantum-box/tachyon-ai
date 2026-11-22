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

    /// What the session is asked for on top of what the gateway configured.
    ///
    /// The gateway's default session is `gpt-realtime-whisper` with nothing but the
    /// language set. That model takes no vocabulary, so names and jargon are guessed
    /// from sound alone. The gateway is asked for the model and hints here instead.
    ///
    /// A gateway that does not know the model yet answers with its default session;
    /// the same settings are then sent as a `session.update` once the connection is
    /// up. That path can go once every gateway issues the model.
    ///
    /// Measured on the same recordings (`--transcribe`, see the README): a model that
    /// takes keywords gets product and personal names right that the default misses,
    /// at the same speed. A longer `delay` and server-side noise reduction changed
    /// nothing, so neither is set.
    struct Tuning: Equatable {
        /// Transcription model; nil keeps the gateway's.
        var model: String?
        /// Words the model should expect. `gpt-realtime-whisper` does not take them.
        var keywords: [String] = []
        /// Free-form context and style for the model. `gpt-realtime-whisper` does not take it.
        var prompt = ""

        /// The gateway's session, untouched.
        static let none = Tuning()

        var isEmpty: Bool { self == .none }

        /// The model alone, for when the keywords or the prompt are refused.
        var modelOnly: Tuning { Tuning(model: model) }

        /// The keywords in the form the gateway and the API accept: single lines
        /// without angle brackets, at most 100 of at most 100 characters.
        var acceptedKeywords: [String] {
            keywords
                .map { $0.components(separatedBy: CharacterSet(charactersIn: "<>\r\n")).joined(separator: " ") }
                .map { String($0.trimmingCharacters(in: .whitespaces).prefix(100)) }
                .filter { !$0.isEmpty }
                .prefix(100)
                .map { $0 }
        }

        /// The prompt within the gateway's limit of 2000 characters.
        var acceptedPrompt: String {
            String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        }
    }

    private let loadConfig: () async throws -> Config
    let tuning: Tuning
    /// Tunings still to try, most complete first; the session opens with the first
    /// one the server accepts, or as the gateway made it when none is.
    private var tuningSteps: [(name: String, tuning: Tuning)] = []
    private var pendingTuningID: String?
    private var tuningTimeout: Task<Void, Never>?
    /// The transcription settings the gateway chose, as reported by the server.
    private var gatewayTranscription: [String: Any] = [:]
    private var config: Config?
    /// The gateway's ID for this session, for reporting how much audio it was sent.
    private var sessionID: String?
    private var usageReported = false
    /// Every event as received, for the evaluation tool.
    var onRawEvent: ((String) -> Void)?
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
        /// Milliseconds of audio actually sent to the server.
        var sentAudioMilliseconds = 0
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
        /// The transcription model the session ended up with.
        var model = "-"
        /// Where the tuning came from: "gateway" when the session was issued with it,
        /// "full" or "model" when it was applied after connecting, "none" when refused.
        var tuning = "none"
    }

    /// Called once the confirmed transcript has arrived (or been given up on).
    var onSettled: ((Metrics) -> Void)?

    /// `loadConfig` runs while audio is already being buffered, so it may refresh the token.
    init(loadConfig: @escaping () async throws -> Config, tuning: Tuning = .none) {
        self.loadConfig = loadConfig
        self.tuning = tuning
        if !tuning.isEmpty {
            tuningSteps.append(("full", tuning))
            if tuning.modelOnly != tuning, !tuning.modelOnly.isEmpty {
                tuningSteps.append(("model", tuning.modelOnly))
            }
        }
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
        // 24 kHz, 16-bit mono: 48 bytes per millisecond.
        metrics.sentAudioMilliseconds = sentBytes / 48

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
            await reportUsageOnce()
            cancel()
            onSettled?(metrics)
        }
    }

    /// Tells the gateway how much audio the session was sent. The audio goes straight
    /// to OpenAI, so this report is the only way the gateway can meter the dictation.
    ///
    /// Every way a session ends comes through here (confirmed, failed, cancelled), and
    /// only the first one reports. A session that was sent no audio reports nothing.
    private func reportUsageOnce() async {
        guard !usageReported, let config, let sessionID, sentBytes > 0 else { return }
        usageReported = true
        // The token from when the connection was opened may have expired since: a
        // standby connection waits up to half an hour. The tenant stays the session's.
        let token = (try? await loadConfig())?.bearerToken ?? config.bearerToken
        var request = URLRequest(url: config.apiURL.appendingPathComponent("v1/ai/realtime/transcription-usage"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.operatorID, forHTTPHeaderField: "x-operator-id")
        // 24 kHz, 16-bit mono: 48,000 bytes per second, rounded up.
        var body: [String: Any] = ["session_id": sessionID, "audio_seconds": (sentBytes + 47_999) / 48_000]
        // The model the session ran on selects the price.
        if metrics.model != "-" { body["model"] = metrics.model }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                NSLog("TachyonAI: usage report refused (%d): %@", status,
                      String(data: data.prefix(200), encoding: .utf8) ?? "")
            }
        } catch {
            NSLog("TachyonAI: usage report failed: %@", error.localizedDescription)
        }
    }

    func cancel() {
        // A dictation that was cancelled or failed still used the audio it sent.
        Task { await reportUsageOnce() }
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
            self.config = config
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
        var body: [String: Any] = [
            "mode": "whisper",
            "transcription": config.language,
            "vad": "off",
        ]
        if let model = tuning.model {
            body["model"] = model
            if !tuning.acceptedKeywords.isEmpty { body["transcription_keywords"] = tuning.acceptedKeywords }
            if !tuning.acceptedPrompt.isEmpty { body["transcription_prompt"] = tuning.acceptedPrompt }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let secret = json["client_secret"] as? String else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw TranscribeError.gateway(status, body)
        }
        sessionID = json["session_id"] as? String
        // The gateway names the model it issued; when that is the one asked for,
        // the hints are already in the session.
        if let model = tuning.model, json["model"] as? String == model {
            tuningSteps = []
            metrics.tuning = "gateway"
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
        onRawEvent?(text)

        switch type {
        case "session.created":
            gatewayTranscription = Self.transcription(in: event) ?? [:]
            metrics.model = gatewayTranscription["model"] as? String ?? "-"
            applyNextTuning()
        case "session.updated":
            guard pendingTuningID != nil else { break }
            pendingTuningID = nil
            if let model = Self.transcription(in: event)?["model"] as? String {
                metrics.model = model
            }
            open()
        case "error" where pendingTuningID != nil:
            // Nothing else has been sent yet, so this is the server refusing the tuning
            // (a model it does not offer, a field the model does not take); not every
            // such error names the event. The session itself is fine: try a smaller one.
            let message = (event["error"] as? [String: Any])?["message"] as? String ?? ""
            NSLog("TachyonAI: transcription tuning '%@' refused: %@", metrics.tuning, message)
            applyNextTuning()
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

    // MARK: - Tuning

    private static func transcription(in event: [String: Any]) -> [String: Any]? {
        let session = event["session"] as? [String: Any]
        let audio = session?["audio"] as? [String: Any]
        let input = audio?["input"] as? [String: Any]
        return input?["transcription"] as? [String: Any]
    }

    /// Sends the next tuning and holds audio back until the server has answered, so
    /// the whole dictation is transcribed with one configuration.
    private func applyNextTuning() {
        tuningTimeout?.cancel()
        guard !tuningSteps.isEmpty else {
            // Reached with a pending tuning only when every one was refused.
            if pendingTuningID != nil { metrics.tuning = "none" }
            pendingTuningID = nil
            open()
            return
        }
        let step = tuningSteps.removeFirst()
        let id = "tuning-\(step.name)"
        pendingTuningID = id
        metrics.tuning = step.name
        sendJSON(["type": "session.update", "event_id": id, "session": sessionUpdate(for: step.tuning)])
        // An answer that never comes must not hold the dictation up.
        tuningTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.pendingTuningID == id else { return }
            self.tuningSteps = []
            self.applyNextTuning()
        }
    }

    private func sessionUpdate(for tuning: Tuning) -> [String: Any] {
        // Starts from the gateway's settings: an update replaces the object as a whole.
        // Unset fields come back as null, which the API does not take back.
        var transcription = gatewayTranscription.filter { !($0.value is NSNull) }
        if transcription["language"] == nil, let language = config?.language {
            transcription["language"] = language
        }
        if let model = tuning.model { transcription["model"] = model }
        if !tuning.acceptedKeywords.isEmpty { transcription["keywords"] = tuning.acceptedKeywords }
        if !tuning.acceptedPrompt.isEmpty { transcription["prompt"] = tuning.acceptedPrompt }

        return ["type": "transcription", "audio": ["input": ["transcription": transcription]]]
    }

    private func open() {
        tuningTimeout?.cancel()
        metrics.openedAt = Date()
        isOpen = true
        pending.forEach(send)
        pending = []
        wake()
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

extension RealtimeTranscriber.Tuning {
    /// What a dictation asks for: the configured model, the user's vocabulary as
    /// keywords, and how the text should be written, followed by their background.
    @MainActor
    static func dictation() -> Self {
        let settings = Settings.load()
        guard !settings.transcriptionModel.isEmpty else { return .none }
        let vocabulary = Vocabulary.shared
        let style = settings.language == "ja"
            ? "音声入力の書き起こし。数字は算用数字で書き、句読点を付ける。"
            : "Dictation. Write numbers as digits and add punctuation."
        let background = vocabulary.background.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            model: settings.transcriptionModel,
            keywords: vocabulary.keywords,
            prompt: background.isEmpty ? style : style + "\n" + background)
    }
}
