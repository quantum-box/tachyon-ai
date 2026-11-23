import SwiftUI

/// Conversation list and the open conversation. On iPhone the two are stacked;
/// on iPad they sit side by side.
struct ChatScreen: View {
    let app: AppState
    @ObservedObject var model: ChatModel
    @ObservedObject var dictation: Dictation

    @State private var column = NavigationSplitViewColumn.detail
    @State private var showingSettings = false
    @FocusState private var inputFocused: Bool

    private static let suggestions = [
        "今日やることを整理したい",
        "この文章を要約して",
        "アイデアを一緒に考えて",
    ]

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $column) {
            sidebar
        } detail: {
            conversation
        }
        .sheet(isPresented: $showingSettings) {
            SettingsScreen(app: app, model: model)
        }
        .task {
            model.restoreLastConversation()
            await model.refreshSessions()
            await model.refreshModels()
        }
    }

    private func startNewChat() {
        withAnimation(.bouncy) { model.startNewChat() }
        column = .detail
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding(
            get: { model.sessionID },
            set: { id in
                guard let id else { return }
                model.open(id)
                column = .detail
            }
        )) {
            ForEach(model.sessions) { session in
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name?.isEmpty == false ? session.name! : "新規チャット")
                        .lineLimit(1)
                    if let updatedAt = session.updatedAt {
                        Text(updatedAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(session.id)
            }
        }
        .navigationTitle("履歴")
        .scrollContentBackground(.hidden)
        .background { AppBackdrop() }
        .overlay {
            if let error = model.sessionsError, model.sessions.isEmpty {
                ContentUnavailableView(
                    "履歴を読み込めませんでした", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.sessions.isEmpty {
                ContentUnavailableView("履歴はまだありません", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .refreshable { await model.refreshSessions() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Label("設定", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: startNewChat) {
                    Label("新規チャット", systemImage: "square.and.pencil")
                }
            }
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        transcript
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .background { AppBackdrop() }
            .navigationTitle(currentTitle)
            .dropDestination(for: URL.self) { urls, _ in
                model.attach(urls: urls)
                return true
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: startNewChat) {
                        Label("新規チャット", systemImage: "square.and.pencil")
                    }
                    .disabled(model.sessionID == nil && model.messages.isEmpty)
                }
            }
    }

    private var currentTitle: String {
        guard let name = model.sessions.first(where: { $0.id == model.sessionID })?.name, !name.isEmpty else {
            return "Tachyon AI"
        }
        return name
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Bubbles share one container so the system can draw them together.
                // The spacing is below the gap between bubbles, so they never fuse.
                GlassEffectContainer(spacing: 6) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.isLoadingHistory {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                        } else if model.messages.isEmpty {
                            welcome
                        }
                        ForEach(model.messages) { message in
                            MessageRow(
                                message: message,
                                // Only the newest question can still be answered.
                                onOption: message.id == model.messages.last?.id && !model.isRunning
                                    ? { model.send($0) } : nil)
                        }
                        if let activity = model.activity {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(activity).font(.callout)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .glassEffect(.regular, in: .capsule)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(16)
                }
                .animation(.bouncy(duration: 0.4), value: model.messages.count)
                .animation(.smooth(duration: 0.25), value: model.activity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.last?.text) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .onChange(of: model.messages.count) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    private static let bottomID = "bottom"

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 84, height: 84)
                .glassEffect(.regular.interactive(), in: .circle)

            VStack(spacing: 6) {
                Text("Tachyon AI").font(.title2.weight(.semibold))
                Text("メッセージを送るか、マイクで話しかけてください。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        model.draft = suggestion
                        inputFocused = true
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    // MARK: - Composer

    /// One glass panel holding the message field and, under it, the controls.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = dictation.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            AttachmentChips(model: model)
            if dictation.phase != .idle {
                dictationStatus
            } else {
                TextField("メッセージ", text: $model.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .padding(.horizontal, 4)
            }

            HStack(spacing: 8) {
                AttachmentButton(model: model)
                ModelControl(model: model) { showingSettings = true }
                Spacer(minLength: 0)
                microphoneButton
                sendButton
            }
        }
        .padding(14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.top, 6)
        .animation(.bouncy(duration: 0.35), value: model.isRunning)
        .animation(.smooth(duration: 0.2), value: dictation.phase)
    }

    private var dictationStatus: some View {
        HStack(spacing: 10) {
            if dictation.phase == .recording {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(dictation.partial.isEmpty
                ? (dictation.phase == .recording ? "聞いています…" : "文字起こし中…")
                : dictation.partial)
                .lineLimit(3)
                .truncationMode(.head)
                .foregroundStyle(dictation.partial.isEmpty ? .secondary : .primary)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
    }

    private var microphoneButton: some View {
        Button {
            inputFocused = false
            dictation.toggle { text in
                // Dictated text is added to whatever is already typed.
                model.draft += model.draft.isEmpty || model.draft.hasSuffix(" ") || model.draft.hasSuffix("\n")
                    ? text : " " + text
            }
        } label: {
            Image(systemName: dictation.phase == .recording ? "stop.fill" : "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(dictation.phase == .recording ? Color.white : Color.primary)
                .frame(width: 38, height: 38)
                .background(
                    dictation.phase == .recording ? AnyShapeStyle(Color.red) : AnyShapeStyle(.quaternary),
                    in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(dictation.phase == .transcribing || model.isRunning)
        .accessibilityLabel(dictation.phase == .recording ? "音声入力を終了" : "音声入力")
    }

    private var sendButton: some View {
        Button {
            if model.isRunning {
                model.stop()
            } else {
                model.send()
                inputFocused = false
            }
        } label: {
            Image(systemName: model.isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(model.isRunning ? Color.red : Color.accentColor))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!model.isRunning && (!model.canSend || dictation.phase != .idle))
        .accessibilityLabel(model.isRunning ? "停止" : "送信")
    }
}
