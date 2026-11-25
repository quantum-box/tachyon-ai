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
    /// Names of the files sent with a user message.
    var attachments: [String] = []
    /// The files themselves, for messages sent in this run of the app
    /// (history from the server has only the names).
    var files: [Attachment] = []
    /// What an assistant reply used, summed over its model round trips.
    var usage: TokenUsage?
}

/// Builds the on-screen messages from agent events, the same way for a live turn
/// and for a conversation replayed from history.
struct Transcript {
    private(set) var messages: [ChatMessage] = []
    private var lastSource: AgentEvent.TextSource?

    /// Tokens and cost of the whole conversation.
    var usage: TokenUsage? {
        messages.compactMap(\.usage).reduce(nil) { total, next in (total ?? TokenUsage()) + next }
    }

    mutating func appendUser(_ text: String, files: [Attachment]) {
        messages.append(ChatMessage(role: .user, text: text, attachments: files.map(\.filename), files: files))
        lastSource = nil
    }

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
        case .usage(let usage):
            let index = replyIndex()
            messages[index].usage = (messages[index].usage ?? TokenUsage()) + usage
        case .failure(let message):
            let index = replyIndex()
            if !messages[index].text.isEmpty {
                messages[index].text += "\n\n"
            }
            messages[index].text += message
            messages[index].failed = true
        case .activity, .openPage, .readPage, .workspace:
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
    /// Why the conversation list could not be loaded, if it could not.
    @Published private(set) var sessionsError: String?
    /// Why renaming or deleting a conversation failed, until the user dismisses it.
    @Published var sessionActionError: String?
    /// The open conversation; nil for a new chat that has not been sent yet.
    @Published private(set) var sessionID: String? {
        didSet { Preferences.lastSessionID = sessionID }
    }
    @Published var draft = ""
    /// Files waiting to go out with the next message.
    @Published private(set) var attachments: [Attachment] = []
    @Published var attachmentError: String?
    @Published private(set) var isRunning = false
    @Published private(set) var isLoadingHistory = false
    /// What the agent is doing while no text is arriving.
    @Published private(set) var activity: String?

    /// Everything used through this app since the total was last reset.
    @Published private(set) var totalUsage = Preferences.totalUsage {
        didSet { Preferences.totalUsage = totalUsage }
    }

    func resetTotalUsage() {
        totalUsage = TokenUsage()
    }

    /// Tools the app runs itself, offered to the agent: the Mac's side pane. None on iOS.
    var clientTools: [[String: Any]] = []
    /// Shows a page the agent asked to open (live replies only, never history).
    var onOpenPage: ((URL) -> Void)?
    /// The open page's text for the agent, or why there is none (`isError`).
    /// May wait for the user to agree.
    var onReadPage: (() async -> (text: String, isError: Bool))?
    /// Asks the user whether the agent may write a file in the project's folder.
    /// Without it, writes are declined unless the project allows them.
    var onConfirmWrite: ((Project, WorkspaceTools.WriteRequest) async -> Bool)?

    // MARK: - Projects

    @Published private(set) var projects = ProjectStore.load() {
        didSet { ProjectStore.save(projects) }
    }
    /// The project a new chat will start in; the open conversation keeps its own.
    @Published private(set) var newChatProjectID: String?

    /// The open conversation's project, or the one a new chat starts in.
    var currentProject: Project? {
        let id = sessionID.map { id in sessions.first { $0.id == id }?.projectID } ?? newChatProjectID
        return id.flatMap(project)
    }

    func project(_ id: String) -> Project? {
        projects.first { $0.id == id }
    }

    func saveProject(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
    }

    /// Forgets the project on this device. Its conversations stay on the server and
    /// show under the history again.
    func deleteProject(_ id: String) {
        projects.removeAll { $0.id == id }
        if newChatProjectID == id { newChatProjectID = nil }
    }

    /// Picks the project for the chat that has not been sent yet.
    func setNewChatProject(_ id: String?) {
        guard sessionID == nil else { return }
        newChatProjectID = id
    }

    // MARK: - Pins

    @Published private(set) var pinnedSessionIDs = Preferences.pinnedSessionIDs {
        didSet { Preferences.pinnedSessionIDs = pinnedSessionIDs }
    }

    func isPinned(_ id: String) -> Bool { pinnedSessionIDs.contains(id) }

    func togglePin(_ id: String) {
        if let index = pinnedSessionIDs.firstIndex(of: id) {
            pinnedSessionIDs.remove(at: index)
        } else {
            pinnedSessionIDs.insert(id, at: 0)
        }
    }

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

    /// The selected model's display name, for buttons and titles.
    var selectedModelName: String {
        guard let id = selectedModel else { return "モデル" }
        return models.first { $0.id == id }?.name ?? id
    }

    /// Whether the thinking-effort setting does anything for the selected model.
    var effortApplies: Bool {
        selectedModel.map(ReasoningEffort.isSupported) ?? false
    }

    var messages: [ChatMessage] { transcript.messages }

    private let api: TachyonAPI
    /// The configured default chat model, known once the model list has loaded.
    private var defaultModel: String?
    private var turn: Task<Void, Never>?
    /// Client tool calls (page reads, workspace tools) the agent is waiting on; they end
    /// with the turn that asked for them.
    private var pageReads: [Task<Void, Never>] = []
    /// Bumped whenever the open conversation changes, so stale work stops touching it.
    private var generation = 0

    init(api: TachyonAPI) {
        self.api = api
    }

    // MARK: - Sending

    /// Whether there is something to send: text, or files on their own.
    var canSend: Bool {
        !isRunning && !isLoadingHistory
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    /// Sends `text`, or the draft (with its attachments) when none is given.
    func send(_ text: String? = nil) {
        var task = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        // Attachments belong to the draft, not to a tapped suggestion or answer.
        let files = text == nil ? attachments : []
        if task.isEmpty, !files.isEmpty {
            // The API needs a task; files alone are a request to look at them.
            task = "添付したファイルを確認してください。"
        }
        guard !task.isEmpty, !isRunning, !isLoadingHistory else { return }
        if text == nil {
            // What the user wrote themselves spells their product and proper names right.
            Vocabulary.shared.learn(fromTyped: task)
            draft = ""
            attachments = []
            attachmentError = nil
        }
        transcript.appendUser(task, files: files)
        isRunning = true
        activity = "接続中…"
        let project = currentProject
        var tools = clientTools
        if project?.folderBookmark != nil {
            tools += WorkspaceTools.definitions
        }

        let generation = self.generation
        turn = Task {
            do {
                let sessionID: String
                if let existing = self.sessionID {
                    sessionID = existing
                } else {
                    sessionID = try await api.createSession(projectID: project?.id)
                    guard generation == self.generation else { return }
                    sessions.insert(
                        SessionSummary(id: sessionID, name: nil, updatedAt: Date(), projectID: project?.id), at: 0)
                    self.sessionID = sessionID
                }
                let events = api.execute(
                    sessionID: sessionID, task: task, model: selectedModel, effort: effort,
                    attachments: files, clientTools: tools, instructions: project?.agentInstructions)
                for try await event in events {
                    guard generation == self.generation else { return }
                    if case .usage(let usage) = event {
                        // Only live replies count; a conversation reopened from history does not.
                        totalUsage = totalUsage + usage
                    }
                    if case .openPage(let url) = event {
                        onOpenPage?(url)
                    }
                    if case .readPage(let toolID) = event {
                        answerReadPage(sessionID: sessionID, toolID: toolID)
                    }
                    if case .workspace(let name, let toolID, let args) = event {
                        answerWorkspace(name, args: args, project: project, sessionID: sessionID, toolID: toolID)
                    }
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
            // The run is over (finished, failed or ended by the server): a prompt still
            // open would answer a run that is gone.
            cancelPageReads()
            // The server names a conversation after its first turn.
            await refreshSessions()
        }
    }

    /// Sends the open page (once the user agrees) to the agent, which waits for it.
    private func answerReadPage(sessionID: String, toolID: String) {
        let generation = self.generation
        pageReads.append(Task {
            let answer = await onReadPage?()
                ?? (text: "No browser pane is available in this app.", isError: true)
            // Stopped, or the conversation changed while the user was deciding: the run is gone.
            guard !Task.isCancelled, generation == self.generation else { return }
            do {
                try await api.submitToolResult(
                    sessionID: sessionID, toolID: toolID, result: answer.text, isError: answer.isError)
            } catch {
                guard generation == self.generation else { return }
                transcript.apply(.failure(error.localizedDescription))
            }
        })
    }

    /// Runs a workspace tool in the project's folder and sends the result to the agent.
    private func answerWorkspace(
        _ name: String, args: [String: Any], project: Project?, sessionID: String, toolID: String
    ) {
        let generation = self.generation
        if name == WorkspaceTools.write {
            activity = "ファイルを書き込み中…"
        } else {
            activity = "フォルダを読み込み中…"
        }
        pageReads.append(Task {
            let answer: (text: String, isError: Bool)
            if let project, let root = project.resolveFolder() {
                answer = await WorkspaceTools.run(name, args: args, root: root) { [weak self] request in
                    // The current setting: "always allow" chosen earlier in this turn counts.
                    let current = self?.project(project.id) ?? project
                    if current.allowsWritesWithoutAsking { return true }
                    return await self?.onConfirmWrite?(project, request) ?? false
                }
            } else {
                answer = ("The project's folder is not available on this device.", true)
            }
            guard !Task.isCancelled, generation == self.generation else { return }
            do {
                try await api.submitToolResult(
                    sessionID: sessionID, toolID: toolID, result: answer.text, isError: answer.isError)
            } catch {
                guard generation == self.generation else { return }
                transcript.apply(.failure(error.localizedDescription))
            }
        })
    }

    // MARK: - Attachments

    func attach(urls: [URL]) {
        add(urls.map { url in { try AttachmentLoader.load(url: url) } })
    }

    func attach(imageData: Data, name: String) {
        add([{ try AttachmentLoader.load(imageData: imageData, name: name) }])
    }

    func removeAttachment(_ id: Attachment.ID) {
        attachments.removeAll { $0.id == id }
        attachmentError = nil
    }

    /// Adds what loads and fits; the first problem is reported, the rest still go in.
    private func add(_ loaders: [() throws -> Attachment]) {
        attachmentError = nil
        for load in loaders {
            do {
                let file = try load()
                let total = attachments.reduce(file.data.count) { $0 + $1.data.count }
                guard total <= AttachmentLoader.maximumTotalBytes else { throw AttachmentError.tooLarge }
                attachments.append(file)
            } catch {
                attachmentError = attachmentError ?? error.localizedDescription
            }
        }
    }

    /// Closing the connection is how a run is cancelled; there is no cancel endpoint.
    func stop() {
        turn?.cancel()
        cancelPageReads()
    }

    /// Ends page reads still waiting on the user, which also closes their prompt.
    private func cancelPageReads() {
        pageReads.forEach { $0.cancel() }
        pageReads = []
    }

    // MARK: - Conversations

    /// Reopens the conversation that was on screen when the app last quit.
    func restoreLastConversation() {
        guard sessionID == nil, messages.isEmpty, let last = Preferences.lastSessionID else { return }
        open(last)
    }

    /// A new chat, in `projectID` or, by default, in the open conversation's project.
    func startNewChat(in projectID: String?? = nil) {
        let project = projectID ?? currentProject?.id
        resetConversation()
        sessionID = nil
        newChatProjectID = project
    }

    func rename(_ id: String, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let old = sessions[index].name
        sessions[index].name = name
        do {
            try await api.renameSession(id, to: name)
        } catch {
            if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].name = old }
            sessionActionError = error.localizedDescription
        }
    }

    /// Deletes a conversation on the server. The open one makes way for a new chat.
    func delete(_ id: String) async {
        do {
            try await api.deleteSession(id)
        } catch {
            sessionActionError = error.localizedDescription
            return
        }
        if sessionID == id { startNewChat() }
        sessions.removeAll { $0.id == id }
        pinnedSessionIDs.removeAll { $0 == id }
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
        let latest: [SessionSummary]
        do {
            latest = try await api.listSessions()
            sessionsError = nil
        } catch {
            // Shown in place of the list: an empty history and a failed request look alike otherwise.
            sessionsError = error.localizedDescription
            return
        }
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
