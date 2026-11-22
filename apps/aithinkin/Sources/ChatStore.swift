import Combine
import Foundation
import FoundationModels
import LiteRTLM

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    var id = UUID()
    var role: Role
    var text: String
    /// An error shown in place of an answer. Never sent back to the model.
    var failed = false
}

/// Which on-device model answers.
enum ModelChoice: String, CaseIterable, Identifiable {
    case apple
    case gemma

    var id: Self { self }

    var title: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .gemma: "Gemma 4"
        }
    }
}

struct Conversation: Identifiable, Codable {
    var id = UUID()
    var title: String
    var updatedAt: Date
    var messages: [ChatMessage]
}

/// The conversations on this device and the on-device models that answer them.
@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var currentID: UUID?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isRunning = false
    @Published private(set) var availability = SystemLanguageModel.default.availability
    @Published var draft = ""
    @Published var choice: ModelChoice {
        didSet {
            guard choice != oldValue else { return }
            UserDefaults.standard.set(choice.rawValue, forKey: Self.choiceKey)
            stop()
            session = nil
            if oldValue == .gemma {
                releaseGemma()
            }
            refreshAvailability()
        }
    }
    @Published var instructions: String {
        didSet {
            UserDefaults.standard.set(instructions, forKey: Self.instructionsKey)
            // The session was created with the old instructions.
            session = nil
        }
    }

    static let defaultInstructions = "あなたは親切なアシスタントです。ユーザーと同じ言語で、簡潔に答えてください。回答には Markdown を使えます。"

    let gemma = GemmaDownload()

    private static let instructionsKey = "instructions"
    private static let choiceKey = "model"
    /// The on-device model's context is small, so only the tail of a conversation is replayed.
    private static let historyBudget = 3000
    private static let reducedHistoryBudget = 600

    private let model = SystemLanguageModel.default
    private var session: LanguageModelSession?
    private var task: Task<Void, Never>?
    /// Counts answers, so one that was stopped cannot end the answer that follows it.
    private var turn = 0
    private var gemmaObserver: AnyCancellable?
    /// Gemma, once loaded. Loading takes seconds, so it is kept between answers.
    private var gemmaEngine: Engine?
    /// The answer Gemma is producing, kept so that it can be stopped.
    private var gemmaConversation: LiteRTLM.Conversation?

    init() {
        instructions = UserDefaults.standard.string(forKey: Self.instructionsKey) ?? Self.defaultInstructions
        let saved = UserDefaults.standard.string(forKey: Self.choiceKey).flatMap(ModelChoice.init)
        choice = saved ?? .apple
        conversations = Self.load()
        // Screens watch this object, so the download's progress is passed on through it.
        gemmaObserver = gemma.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    /// Whether the chosen model can answer right now.
    var isReady: Bool {
        switch choice {
        case .apple: availability == .available
        case .gemma: gemma.state == .ready
        }
    }

    /// Removes the Gemma file and frees the memory the loaded model holds.
    func deleteGemma() {
        if choice == .gemma {
            stop()
            session = nil
        }
        releaseGemma()
        gemma.delete()
    }

    /// Frees the memory the loaded Gemma model holds.
    private func releaseGemma() {
        gemmaConversation = nil
        gemmaEngine = nil
    }

    var currentTitle: String? {
        conversations.first { $0.id == currentID }?.title
    }

    /// Apple Intelligence can be switched on, or finish downloading, while the app is in the background.
    func refreshAvailability() {
        availability = model.availability
        if choice == .apple, availability == .available, session == nil, messages.isEmpty {
            // Loads the model before the first message, so the first answer starts sooner.
            session = makeSession(history: [], budget: Self.historyBudget)
            session?.prewarm()
        }
    }

    func startNewChat() {
        stop()
        currentID = nil
        messages = []
        session = nil
    }

    func open(_ id: UUID) {
        guard id != currentID, let conversation = conversations.first(where: { $0.id == id }) else { return }
        stop()
        currentID = id
        messages = conversation.messages
        session = nil
    }

    func delete(_ id: UUID) {
        if id == currentID {
            startNewChat()
        }
        conversations.removeAll { $0.id == id }
        save()
    }

    func deleteAll() {
        startNewChat()
        conversations = []
        save()
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning, isReady else { return }
        draft = ""
        let history = messages
        messages.append(ChatMessage(role: .user, text: text))
        messages.append(ChatMessage(role: .assistant, text: ""))
        isRunning = true
        store()
        turn += 1
        let turn = turn

        task = Task {
            do {
                try await respond(to: text, history: history, budget: Self.historyBudget)
            } catch where Self.isContextOverflow(error) {
                // Start over with less of the conversation; the visible messages stay.
                do {
                    session = nil
                    setAnswer("")
                    try await respond(to: text, history: history, budget: Self.reducedHistoryBudget)
                } catch {
                    fail(error)
                }
            } catch {
                fail(error)
            }
            if turn == self.turn {
                finish()
            }
        }
    }

    /// Ends the answer where it is and keeps what has arrived so far.
    func stop() {
        guard isRunning else { return }
        task?.cancel()
        try? gemmaConversation?.cancel()
        finish()
        turn += 1
        // The session never recorded the partial answer, and may still be producing it.
        session = nil
    }

    private func respond(to text: String, history: [ChatMessage], budget: Int) async throws {
        if choice == .gemma {
            try await respondWithGemma(to: text, history: history, budget: budget)
            return
        }
        let session = self.session ?? makeSession(history: history, budget: budget)
        self.session = session
        for try await snapshot in session.streamResponse(to: text) {
            try Task.checkCancellation()
            setAnswer(snapshot.content)
        }
    }

    private func setAnswer(_ text: String) {
        guard let last = messages.indices.last, messages[last].role == .assistant else { return }
        messages[last].text = text
    }

    private func fail(_ error: Error) {
        guard !(error is CancellationError), !Task.isCancelled else { return }
        guard let last = messages.indices.last, messages[last].role == .assistant else { return }
        messages[last].text = Self.describe(error)
        messages[last].failed = true
    }

    private func finish() {
        guard isRunning else { return }
        isRunning = false
        task = nil
        if messages.last?.role == .assistant, messages.last?.text.isEmpty == true {
            messages.removeLast()
        }
        // A stopped or failed turn leaves the session out of step with what is on screen,
        // so the next message rebuilds it from the visible messages.
        if messages.last?.failed == true || messages.last?.role == .user {
            session = nil
        }
        store()
    }

    // MARK: - Model

    /// The newest messages that fit the budget, oldest first, starting from a question.
    private static func recent(_ history: [ChatMessage], budget: Int) -> [ChatMessage] {
        var kept: [ChatMessage] = []
        var used = 0
        for message in history.reversed() where !message.failed && !message.text.isEmpty {
            used += message.text.count
            if used > budget { break }
            kept.append(message)
        }
        // A history that opens with an answer has lost the question it belongs to.
        while kept.last?.role == .assistant {
            kept.removeLast()
        }
        return kept.reversed()
    }

    private var effectiveInstructions: String {
        let text = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? Self.defaultInstructions : text
    }

    private func makeSession(history: [ChatMessage], budget: Int) -> LanguageModelSession {
        let opening = Transcript.Entry.instructions(.init(
            segments: [.text(.init(content: effectiveInstructions))], toolDefinitions: []))
        let entries = Self.recent(history, budget: budget).map { message -> Transcript.Entry in
            let segments = [Transcript.Segment.text(.init(content: message.text))]
            switch message.role {
            case .user: return .prompt(.init(segments: segments))
            case .assistant: return .response(.init(assetIDs: [], segments: segments))
            }
        }
        return LanguageModelSession(model: model, transcript: Transcript(entries: [opening] + entries))
    }

    // MARK: - Gemma

    private func respondWithGemma(to text: String, history: [ChatMessage], budget: Int) async throws {
        let engine = try await loadGemma()
        // Each answer starts from the visible messages, so nothing has to be kept in step.
        let conversation = try await engine.createConversation(with: ConversationConfig(
            systemMessage: Message(effectiveInstructions, role: .system),
            initialMessages: Self.recent(history, budget: budget).map {
                Message($0.text, role: $0.role == .user ? .user : .model)
            }))
        gemmaConversation = conversation
        var answer = ""
        for try await chunk in conversation.sendMessageStream(Message(text)) {
            try Task.checkCancellation()
            answer += chunk.toString
            setAnswer(answer)
        }
    }

    private func loadGemma() async throws -> Engine {
        if let gemmaEngine {
            return gemmaEngine
        }
        // The simulator has no GPU that the runtime can use.
        #if targetEnvironment(simulator)
        let backend = Backend.cpu()
        #else
        let backend = Backend.gpu
        #endif
        let engine = Engine(engineConfig: try EngineConfig(
            modelPath: GemmaDownload.fileURL.path, backend: backend, maxNumTokens: 4096,
            cacheDir: URL.cachesDirectory.path))
        try await engine.initialize()
        gemmaEngine = engine
        return engine
    }

    private static func isContextOverflow(_ error: Error) -> Bool {
        if #available(iOS 27.0, *), case LanguageModelError.contextSizeExceeded = error {
            return true
        }
        if case LanguageModelSession.GenerationError.exceededContextWindowSize = error {
            return true
        }
        return false
    }

    private static func describe(_ error: Error) -> String {
        if isContextOverflow(error) {
            return "会話が長くなりすぎました。新しいチャットを始めてください。"
        }
        if #available(iOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal:
                return "この内容には答えられません。"
            case .unsupportedLanguageOrLocale:
                return "この言語には対応していません。"
            case .rateLimited:
                return "リクエストが多すぎます。少し待ってから試してください。"
            default:
                break
            }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                return "この内容には答えられません。"
            case .unsupportedLanguageOrLocale:
                return "この言語には対応していません。"
            case .rateLimited:
                return "リクエストが多すぎます。少し待ってから試してください。"
            case .assetsUnavailable:
                return "モデルの準備ができていません。しばらくしてから試してください。"
            default:
                break
            }
        }
        return "回答を作れませんでした。\(error.localizedDescription)"
    }

    // MARK: - Storage

    /// Copies the open conversation into the list and writes the list to disk.
    private func store() {
        guard let first = messages.first else { return }
        if let index = conversations.firstIndex(where: { $0.id == currentID }) {
            conversations[index].messages = messages
            conversations[index].updatedAt = Date()
            conversations.move(fromOffsets: IndexSet(integer: index), toOffset: 0)
        } else {
            let title = first.text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(40)) } ?? "新規チャット"
            let conversation = Conversation(title: title, updatedAt: Date(), messages: messages)
            currentID = conversation.id
            conversations.insert(conversation, at: 0)
        }
        save()
    }

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "conversations.json")
    }

    private static func load() -> [Conversation] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Conversation].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            try encoder.encode(conversations).write(to: Self.fileURL, options: .atomic)
        } catch {
            // The conversation stays in memory; the next save tries again.
        }
    }
}
