import Foundation

struct ChatMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var text: String
    var failed = false
    /// Answers the agent offered to a question it asked.
    var options: [String] = []
}

/// Builds the on-screen messages from agent events, the same way for a live turn
/// and for a conversation replayed from history.
struct Transcript {
    private(set) var messages: [ChatMessage] = []
    private var lastSource: AgentEvent.TextSource?

    mutating func apply(_ event: AgentEvent) {
        switch event {
        case .user(let text):
            messages.append(ChatMessage(role: .user, text: text))
            lastSource = nil
        case .text(let text, let source):
            let index = replyIndex()
            // A different kind of chunk is a new paragraph, not a continuation.
            if let lastSource, lastSource != source, !messages[index].text.isEmpty {
                messages[index].text += "\n\n"
            }
            messages[index].text += text
            lastSource = source
        case .options(let options):
            messages[replyIndex()].options = options
        case .failure(let message):
            let index = replyIndex()
            if !messages[index].text.isEmpty {
                messages[index].text += "\n\n"
            }
            messages[index].text += message
            messages[index].failed = true
        case .activity:
            break
        }
    }

    /// The reply being written: the last message, or a new one after a user message.
    private mutating func replyIndex() -> Int {
        if messages.last?.role != .assistant {
            messages.append(ChatMessage(role: .assistant, text: ""))
        }
        return messages.count - 1
    }
}

/// The chat window's state: the conversation list, the open conversation and the turn in flight.
@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var transcript = Transcript()
    @Published private(set) var sessions: [SessionSummary] = []
    /// The open conversation; nil for a new chat that has not been sent yet.
    @Published private(set) var sessionID: String? {
        didSet { Preferences.lastSessionID = sessionID }
    }
    @Published var draft = ""
    @Published private(set) var isRunning = false
    @Published private(set) var isLoadingHistory = false
    /// What the agent is doing while no text is arriving.
    @Published private(set) var activity: String?

    @Published private(set) var models: [ModelInfo] = []
    /// The model new messages are sent to; nil until the default is known.
    @Published var selectedModel: String? = Preferences.chatModel {
        didSet { Preferences.chatModel = selectedModel }
    }
    @Published var effort: ReasoningEffort = Preferences.reasoningEffort {
        didSet { Preferences.reasoningEffort = effort }
    }

    /// The user's own choice of models to show; nil until they change the default.
    @Published private var enabledModels: Set<String>? = Preferences.enabledModels {
        didSet { Preferences.enabledModels = enabledModels }
    }

    /// The chat window's magnification; 1 is 100%.
    @Published private(set) var zoom = Zoom.clamped(Preferences.zoom) {
        didSet { Preferences.zoom = zoom }
    }

    func zoomIn() { zoom = Zoom.clamped(zoom + Zoom.step) }
    func zoomOut() { zoom = Zoom.clamped(zoom - Zoom.step) }
    func resetZoom() { zoom = 1 }

    /// Whether the thinking-effort setting does anything for the selected model.
    var effortApplies: Bool {
        selectedModel.map(ReasoningEffort.isSupported) ?? false
    }

    var messages: [ChatMessage] { transcript.messages }

    private let api: TachyonAPI
    /// The configured default chat model, known once the model list has loaded.
    private var defaultModel: String?
    private var turn: Task<Void, Never>?
    /// Bumped whenever the open conversation changes, so stale work stops touching it.
    private var generation = 0

    init(api: TachyonAPI) {
        self.api = api
    }

    // MARK: - Sending

    /// Sends `text`, or the draft when none is given.
    func send(_ text: String? = nil) {
        let task = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, !isRunning, !isLoadingHistory else { return }
        if text == nil { draft = "" }
        transcript.apply(.user(task))
        isRunning = true
        activity = "接続中…"

        let generation = self.generation
        turn = Task {
            do {
                let sessionID: String
                if let existing = self.sessionID {
                    sessionID = existing
                } else {
                    sessionID = try await api.createSession()
                    guard generation == self.generation else { return }
                    self.sessionID = sessionID
                    sessions.insert(SessionSummary(id: sessionID, name: nil, updatedAt: Date()), at: 0)
                }
                let events = api.execute(
                    sessionID: sessionID, task: task, model: selectedModel, effort: effort)
                for try await event in events {
                    guard generation == self.generation else { return }
                    if case .activity(let description) = event {
                        activity = description
                    } else {
                        activity = nil
                        transcript.apply(event)
                    }
                }
            } catch is CancellationError {
                // Stopped by the user; keep what arrived.
            } catch let error as URLError where error.code == .cancelled {
                // Same: the connection was closed on purpose.
            } catch {
                guard generation == self.generation else { return }
                transcript.apply(.failure(error.localizedDescription))
            }
            guard generation == self.generation else { return }
            if transcript.messages.last?.role == .user {
                transcript.apply(.failure("(応答なし)"))
            }
            isRunning = false
            activity = nil
            // The server names a conversation after its first turn.
            await refreshSessions()
        }
    }

    /// Closing the connection is how a run is cancelled; there is no cancel endpoint.
    func stop() {
        turn?.cancel()
    }

    // MARK: - Conversations

    /// Reopens the conversation that was on screen when the app last quit.
    func restoreLastConversation() {
        guard sessionID == nil, messages.isEmpty, let last = Preferences.lastSessionID else { return }
        open(last)
    }

    func startNewChat() {
        resetConversation()
        sessionID = nil
    }

    func open(_ id: String) {
        guard id != sessionID else { return }
        resetConversation()
        sessionID = id
        isLoadingHistory = true

        let generation = self.generation
        Task {
            do {
                let events = try await api.history(sessionID: id)
                guard generation == self.generation else { return }
                var loaded = Transcript()
                events.forEach { loaded.apply($0) }
                transcript = loaded
            } catch {
                guard generation == self.generation else { return }
                transcript.apply(.failure(error.localizedDescription))
            }
            isLoadingHistory = false
        }
    }

    func refreshModels() async {
        guard let (models, defaultModel) = try? await api.listModels() else { return }
        self.models = models
        self.defaultModel = defaultModel
        reconcileSelection()
    }

    // MARK: - Enabled models

    /// Providers in the order the server lists them.
    var providers: [String] {
        var seen: [String] = []
        for info in models where !seen.contains(info.provider) {
            seen.append(info.provider)
        }
        return seen
    }

    /// The models offered in the chat's model menu.
    var visibleModels: [ModelInfo] {
        models.filter(isEnabled)
    }

    func isEnabled(_ info: ModelInfo) -> Bool {
        if let enabledModels { return enabledModels.contains(info.id) }
        return Self.isEnabledByDefault(info, among: models)
    }

    func setEnabled(_ enabled: Bool, for infos: [ModelInfo]) {
        // The first change turns the default into an explicit list.
        var current = enabledModels ?? Set(models.filter(isEnabled).map(\.id))
        for info in infos {
            if enabled {
                current.insert(info.id)
            } else {
                current.remove(info.id)
            }
        }
        enabledModels = current
        reconcileSelection()
    }

    func resetEnabledModels() {
        enabledModels = nil
        reconcileSelection()
    }

    /// The GPT-6 family only. If the tenant has none, the menu falls back to everything
    /// rather than being empty.
    private static func isEnabledByDefault(_ info: ModelInfo, among models: [ModelInfo]) -> Bool {
        !models.contains(where: isGPT6) || isGPT6(info)
    }

    private static func isGPT6(_ info: ModelInfo) -> Bool {
        info.provider == "openai" && info.id.contains("gpt-6")
    }

    /// The selected model has to be one the menu shows.
    private func reconcileSelection() {
        let visible = visibleModels
        guard !visible.contains(where: { $0.id == selectedModel }) else { return }
        selectedModel = visible.contains(where: { $0.id == defaultModel }) ? defaultModel : visible.first?.id
    }

    func refreshSessions() async {
        guard let latest = try? await api.listSessions() else { return }
        // A conversation created a moment ago may not be listed by the server yet.
        if let sessionID, !latest.contains(where: { $0.id == sessionID }),
           let current = sessions.first(where: { $0.id == sessionID }) {
            sessions = [current] + latest
        } else {
            sessions = latest
        }
    }

    private func resetConversation() {
        stop()
        generation += 1
        turn = nil
        transcript = Transcript()
        isRunning = false
        isLoadingHistory = false
        activity = nil
    }
}
