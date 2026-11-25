import AppKit
import SwiftUI

/// The agent chat window. Created once and shown again when reopened.
@MainActor
final class ChatWindowController {
    private let model: ChatModel
    private let account: Account
    private let openSettings: () -> Void
    private var window: NSWindow?
    /// The side pane; kept here so the menu's tab commands reach it.
    private let pane = BrowserPaneModel()

    init(model: ChatModel, account: Account, openSettings: @escaping () -> Void) {
        self.model = model
        self.account = account
        self.openSettings = openSettings
    }

    func show() {
        if window == nil {
            // A hosting controller (not a bare hosting view) lets SwiftUI's toolbar and
            // title drive the window's own toolbar, which is drawn in Liquid Glass.
            let hosting = NSHostingController(
                rootView: ChatView(
                    model: model, account: account, pane: pane, openSettings: openSettings,
                    widenWindow: { [weak self] in self?.widen(toAtLeast: $0) }))
            hosting.sceneBridgingOptions = [.toolbars, .title]
            // Otherwise the window grows to the split view's ideal size (the whole screen).
            hosting.sizingOptions = []

            let size = NSSize(width: 860, height: 680)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false)
            window.contentViewController = hosting
            window.toolbarStyle = .unified
            // See-through window: the desktop shows, blurred, behind the glass pieces.
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 420, height: 420)
            window.setContentSize(size)
            window.center()
            window.setFrameAutosaveName("Chat")
            self.window = window
            model.restoreLastConversation()
            // The view appears before `window` is set, so it cannot do this itself.
            if Preferences.browserPaneShown { widen(toAtLeast: ChatView.widthWithPane) }
        }
        window?.bringToFront()
        Task {
            await model.refreshSessions()
            await model.refreshModels()
        }
    }

    /// ⌘T: a new tab in the pane, opening the chat window if needed.
    func newTab() {
        show()
        pane.newTab()
    }

    /// Opens a page in a new tab of the pane, opening the chat window if needed.
    func open(_ url: URL) {
        show()
        pane.open(url)
    }

    /// ⌘L: the address field of the open web tab, or of a new tab.
    func focusAddressBar() {
        show()
        pane.focusAddressBar()
    }

    /// ⌘W while the chat window is in front: closes the pane's tab.
    /// False when there is no tab to close, so the window itself closes.
    func closeTab() -> Bool {
        guard let window, window.isKeyWindow, pane.isShown, let id = pane.selectedTabID else { return false }
        pane.close(id)
        return true
    }

    /// Makes room for the browser pane, without leaving the screen.
    private func widen(toAtLeast width: CGFloat) {
        guard let window, window.frame.width < width,
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(width, visible.width)
        if frame.maxX > visible.maxX {
            frame.origin.x = max(visible.minX, visible.maxX - frame.width)
        }
        // After the SwiftUI update that asked for it, and without animation: resizing
        // inside the update, while replies stream in, looped AppKit's layout.
        DispatchQueue.main.async {
            window.setFrame(frame, display: true, animate: false)
        }
    }
}

extension NSWindow {
    /// A menu-bar-only app is not allowed to bring its window in front of other apps,
    /// so while one of its windows is open the app is a regular one, with a Dock icon.
    /// `AppController` switches back when the last window closes.
    func bringToFront() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }
}

/// Conversation list on the left, the open conversation on the right. Everything
/// is Liquid Glass floating over a blurred view of the desktop.
private struct ChatView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var account: Account
    @ObservedObject var pane: BrowserPaneModel
    let openSettings: () -> Void
    let widenWindow: (CGFloat) -> Void
    @FocusState private var inputFocused: Bool
    @State private var columns = NavigationSplitViewVisibility.all
    /// The agent's request to read the open page, waiting for the user's answer.
    @State private var shareRequest: ShareRequest?
    /// The agent's request to write a file in the project's folder, waiting for the user.
    @State private var writeRequest: WriteConfirmation?
    /// The pane opens at the width it was last left at.
    @State private var paneWidth = min(max(CGFloat(Preferences.browserPaneWidth), PaneDivider.range.lowerBound), PaneDivider.range.upperBound)
    /// Width of the conversation and pane together, so the pane can grow until the
    /// conversation reaches its minimum.
    @State private var detailWidth: CGFloat = 0

    /// Sidebar, conversation and browser pane side by side.
    static var widthWithPane: CGFloat { 800 + Preferences.browserPaneWidth }
    /// The conversation stays readable at this width however wide the pane is dragged.
    static let conversationMinWidth: CGFloat = 280

    private static let suggestions = [
        "今日やることを整理したい",
        "この文章を要約して",
        "アイデアを一緒に考えて",
    ]

    var body: some View {
        // An API key in config.json stands in for a signed-in user.
        if account.isLoggedIn || Settings.load().apiKey != nil {
            chat
                .task(id: account.isLoggedIn) {
                    await model.refreshSessions()
                    await model.refreshModels()
                }
        } else {
            LoginView(account: account)
                .frame(minWidth: 380, minHeight: 420)
                .background { WindowBackdrop().ignoresSafeArea() }
                .navigationTitle("Tachyon AI")
        }
    }

    private var chat: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            // A plain panel rather than `.inspector`: the inspector column's real width
            // drifted from the width its content was laid out at, clipping the pane.
            HStack(spacing: 0) {
                conversation
                if pane.isShown {
                    PaneDivider(width: $paneWidth,
                                maxWidth: detailWidth - Self.conversationMinWidth - PaneDivider.thickness)
                    // Flexible below the saved width: a pane that insisted on its width made
                    // AppKit grow the window mid-layout, which crashed in a layout loop.
                    BrowserPane(pane: pane)
                        .frame(minWidth: 240, idealWidth: paneWidth, maxWidth: paneWidth)
                        .layoutPriority(1)
                        .transition(.move(edge: .trailing))
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
        }
        .background {
            // ⌘B shows and hides the conversation list, as in other Mac apps.
            Button("サイドバー") {
                withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
            }
            .keyboardShortcut("b", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .zoomedFont(.body)
        .environment(\.zoom, model.zoom)
        .environment(\.openURL, OpenURLAction(handler: openLink))
        .background { WindowBackdrop().ignoresSafeArea() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: startNewChat) {
                    Label("新規チャット", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.sessionID == nil && model.messages.isEmpty)
                .help("新規チャット")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation { pane.isShown.toggle() }
                } label: {
                    Label("ブラウザ", systemImage: "sidebar.right")
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .help(pane.isShown ? "ブラウザを隠す (⇧⌘B)" : "ブラウザを表示 (⇧⌘B)")
            }
        }
        .onAppear {
            inputFocused = true
            pane.show(session: model.sessionID)
            // The agent may open pages beside the chat.
            model.clientTools = [
                ClientTools.openInBrowserDefinition(sites: Settings.load().sites),
                ClientTools.readBrowserPageDefinition,
            ]
            // After the current update: a tab created mid-update, while the reply streams
            // in, adds a web view to a layout pass already under way.
            model.onOpenPage = { [pane] url in DispatchQueue.main.async { pane.open(url) } }
            model.onReadPage = { await readPageForAgent() }
            model.onConfirmWrite = { project, request in await confirmWrite(project, request) }
        }
        .alert(
            "ファイルを書き込みますか？",
            isPresented: Binding(get: { writeRequest != nil }, set: { if !$0 { answerWrite(.deny) } }),
            presenting: writeRequest
        ) { confirmation in
            Button(confirmation.request.exists ? "上書きする" : "作成する") { answerWrite(.once) }
                .keyboardShortcut(.defaultAction)
            Button("「\(confirmation.project.name)」では常に許可") { answerWrite(.always) }
            Button("やめる", role: .cancel) { answerWrite(.deny) }
        } message: { confirmation in
            Text(writeMessage(confirmation))
        }
        .alert(
            "このページを AI に渡しますか？",
            isPresented: Binding(get: { shareRequest != nil }, set: { if !$0 { answerShare(.deny) } }),
            presenting: shareRequest
        ) { request in
            Button("渡す") { answerShare(.once) }
                .keyboardShortcut(.defaultAction)
            Button("\(request.url.host() ?? "このサイト") は常に許可") { answerShare(.always) }
            Button("渡さない", role: .cancel) { answerShare(.deny) }
        } message: { request in
            Text("「\(request.title.isEmpty ? request.url.host() ?? "" : request.title)」\n\(request.url.absoluteString)\n\nAI が右のペインのページの文字を読もうとしています。ログイン中のページなら、その内容も送られます。「常に許可」はこのサイトだけに効き、ペインの「…」メニューで解除できます。")
        }
        .onChange(of: pane.isShown) {
            if pane.isShown { widenWindow(Self.widthWithPane) }
        }
        .onChange(of: model.sessionID) { old, new in
            // A new chat gets its ID mid-send; its tabs stay with it.
            pane.show(session: new, adopting: old == nil && model.isRunning)
        }
    }

    /// The open page for the agent, after asking the user unless they always allow it.
    private func readPageForAgent() async -> (text: String, isError: Bool) {
        guard let page = await pane.selectedPageText() else {
            return ("The browser pane has no web page open.", true)
        }
        // "Always" is remembered per host: mail.google.com does not cover docs.google.com.
        let host = page.url.host()?.lowercased() ?? ""
        if !Preferences.sharedPageHosts.contains(host) {
            // Stopping the reply or leaving the conversation cancels the read: close the prompt.
            let answer = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    // One prompt at a time: an older request still waiting is declined, so its
                    // tool call gets an answer instead of hanging.
                    answerShare(.deny)
                    shareRequest = ShareRequest(title: page.title, url: page.url, answer: continuation)
                }
            } onCancel: {
                Task { @MainActor in answerShare(.deny) }
            }
            guard !Task.isCancelled else { return ("The run was stopped.", true) }
            switch answer {
            case .deny:
                return ("The user declined to share the page.", true)
            case .always:
                Preferences.sharedPageHosts.insert(host)
            case .once:
                break
            }
        }
        return ("Title: \(page.title)\nURL: \(page.url.absoluteString)\n\n\(page.text)", false)
    }

    /// Asks before the agent writes into the project's folder.
    private func confirmWrite(_ project: Project, _ request: WorkspaceTools.WriteRequest) async -> Bool {
        let answer = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // One prompt at a time: an older request still waiting is declined.
                answerWrite(.deny)
                writeRequest = WriteConfirmation(project: project, request: request, answer: continuation)
            }
        } onCancel: {
            Task { @MainActor in answerWrite(.deny) }
        }
        switch answer {
        case .deny:
            return false
        case .always:
            var changed = model.project(project.id) ?? project
            changed.allowsWritesWithoutAsking = true
            model.saveProject(changed)
            return true
        case .once:
            return true
        }
    }

    private func writeMessage(_ confirmation: WriteConfirmation) -> String {
        let request = confirmation.request
        let lines = request.content.split(separator: "\n", omittingEmptySubsequences: false)
        var preview = lines.prefix(12).joined(separator: "\n")
        if preview.count > 600 { preview = String(preview.prefix(600)) + "…" }
        if lines.count > 12 { preview += "\n…" }
        let action = request.exists ? "上書き" : "新しく作成"
        return """
            AI が「\(confirmation.project.name)」のフォルダの \(request.path) を\(action)しようとしています (\(lines.count) 行)。

            \(preview)
            """
    }

    private func answerWrite(_ answer: ShareRequest.Answer) {
        guard let request = writeRequest else { return }
        writeRequest = nil
        request.answer.resume(returning: answer)
    }

    /// Resumes the waiting request exactly once.
    private func answerShare(_ answer: ShareRequest.Answer) {
        guard let request = shareRequest else { return }
        shareRequest = nil
        request.answer.resume(returning: answer)
    }

    /// A reply in full, titled after its first line.
    private func openReply(_ message: ChatMessage) {
        let firstLine = message.text.split(separator: "\n").first.map(String.init) ?? ""
        let title = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#*> -").union(.whitespaces))
        pane.openDocument(
            title: title.isEmpty ? "返答" : String(title.prefix(30)), text: message.text, isMarkdown: true)
    }

    /// Web links in the chat open in the browser pane; ⌘-click opens them in the default browser.
    private func openLink(_ url: URL) -> OpenURLAction.Result {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              !NSEvent.modifierFlags.contains(.command) else {
            return .systemAction
        }
        pane.open(url)
        return .handled
    }

    private func startNewChat() {
        withAnimation(.bouncy) { model.startNewChat() }
        inputFocused = true
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ConversationList(model: model) { projectID in
            withAnimation(.bouncy) { model.startNewChat(in: .some(projectID)) }
            inputFocused = true
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        transcript
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .frame(minWidth: Self.conversationMinWidth, minHeight: 420)
            .navigationTitle(currentTitle)
            .navigationSubtitle(model.currentProject?.name ?? "")
            // Files can also be dropped anywhere on the conversation.
            .dropDestination(for: URL.self) { urls, _ in
                model.attach(urls: urls)
                return true
            }
    }

    private var currentTitle: String {
        guard let name = model.sessions.first(where: { $0.id == model.sessionID })?.name, !name.isEmpty else {
            return "Tachyon AI"
        }
        return name
    }

    /// Downloads a file Field stored and shows it in the side pane.
    private func openSharedFile(_ file: SharedFile) {
        Task {
            do {
                switch try await model.load(file) {
                case .file(let attachment): pane.open(attachment)
                case .link(let url): pane.open(url)
                }
            } catch {
                model.attachmentError = "「\(file.name)」を開けませんでした: \(error.localizedDescription)"
            }
        }
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
                                    ? { model.send($0) } : nil,
                                onOpenFile: { pane.open($0) },
                                onOpenSharedFile: openSharedFile,
                                onOpenReply: { openReply(message) })
                                .transition(.scale(scale: 0.9, anchor: message.role == .user ? .bottomTrailing : .bottomLeading)
                                    .combined(with: .opacity))
                        }
                        if let activity = model.activity {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(activity).zoomedFont(.callout)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .glassEffect(.regular, in: .capsule)
                            .transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(16)
                }
                .animation(.bouncy(duration: 0.4), value: model.messages.count)
                .animation(.smooth(duration: 0.25), value: model.activity)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
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
                Text("Tachyon AI").zoomedFont(.title2, weight: .semibold)
                Text("メッセージを送るか、fn を押しながら話しかけてください。")
                    .zoomedFont(.callout)
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
                    .controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }

    /// One glass panel holding the message field and, under it, the controls.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            AttachmentChips(model: model)
            TextField("メッセージ", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .zoomedFont(.body)
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit { model.send() }
                .padding(.horizontal, 6)
                .padding(.top, 4)

            HStack(spacing: 8) {
                AttachmentButton(model: model)
                ProjectControl(model: model)
                ModelControl(model: model, openSettings: openSettings)
                Spacer(minLength: 0)
                sendButton
            }
        }
        .padding(12)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 6)
        .animation(.bouncy(duration: 0.35), value: model.isRunning)
    }

    private var sendButton: some View {
        Button {
            if model.isRunning {
                model.stop()
            } else {
                model.send()
            }
        } label: {
            Image(systemName: model.isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(model.isRunning ? Color.red : Color.accentColor))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!model.isRunning && !model.canSend)
        .help(model.isRunning ? "停止" : "送信")
    }
}

/// The agent asked to read the open page and waits for the user.
private struct ShareRequest {
    enum Answer { case once, always, deny }

    let title: String
    let url: URL
    let answer: CheckedContinuation<Answer, Never>
}

/// The agent asked to write a file and waits for the user.
private struct WriteConfirmation {
    let project: Project
    let request: WorkspaceTools.WriteRequest
    let answer: CheckedContinuation<ShareRequest.Answer, Never>
}

/// The line between the conversation and the side pane; drag it to resize the pane.
private struct PaneDivider: View {
    @Binding var width: CGFloat
    /// The widest the pane can be in the window right now.
    var maxWidth: CGFloat
    @State private var startWidth: CGFloat?

    static let range: ClosedRange<CGFloat> = 300...4000
    /// The 1pt line plus its grab padding.
    static let thickness: CGFloat = 7

    var body: some View {
        // A 1pt line in a strip wide enough to grab.
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .padding(.horizontal, 3)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = startWidth ?? width
                        startWidth = start
                        // Dragging left widens the pane.
                        // Capped at the room left in the window, so dragging back
                        // responds at once instead of first unwinding an overshoot.
                        let upper = max(Self.range.lowerBound, min(Self.range.upperBound, maxWidth))
                        width = min(max(start - drag.translation.width, Self.range.lowerBound), upper)
                    }
                    .onEnded { _ in
                        startWidth = nil
                        Preferences.browserPaneWidth = Double(width)
                    })
    }
}

/// Blurs whatever is behind the window (other apps, the desktop).
private struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        // Stay translucent when the window is not the active one.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The project of the chat: a menu before the first message, a label after.
private struct ProjectControl: View {
    @ObservedObject var model: ChatModel

    var body: some View {
        if model.projects.isEmpty {
            EmptyView()
        } else if model.sessionID == nil {
            Menu {
                Picker("プロジェクト", selection: Binding(
                    get: { model.newChatProjectID },
                    set: { model.setNewChatProject($0) }
                )) {
                    Text("なし").tag(String?.none)
                    ForEach(model.projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                capsule(chevron: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("新しい会話のプロジェクト")
        } else if let project = model.currentProject {
            capsule(chevron: false)
                .help(project.folderPath ?? "この会話のプロジェクト")
        }
    }

    private func capsule(chevron: Bool) -> some View {
        let project = model.currentProject
        return HStack(spacing: 5) {
            Image(systemName: project?.folderPath == nil ? "folder" : "folder.fill")
            Text(project?.name ?? "プロジェクトなし").lineLimit(1)
            if chevron {
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary, in: Capsule())
        .contentShape(Capsule())
    }
}

