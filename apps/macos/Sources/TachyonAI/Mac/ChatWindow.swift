import AppKit
import SwiftUI

/// The agent chat window. Created once and shown again when reopened.
@MainActor
final class ChatWindowController {
    private let model: ChatModel
    private let account: Account
    private let openSettings: () -> Void
    private var window: NSWindow?

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
                rootView: ChatView(model: model, account: account, openSettings: openSettings))
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
        }
        window?.bringToFront()
        Task {
            await model.refreshSessions()
            await model.refreshModels()
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
    let openSettings: () -> Void
    @FocusState private var inputFocused: Bool

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
        NavigationSplitView {
            sidebar
        } detail: {
            conversation
        }
        .zoomedFont(.body)
        .environment(\.zoom, model.zoom)
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
        }
        .onAppear { inputFocused = true }
    }

    private func startNewChat() {
        withAnimation(.bouncy) { model.startNewChat() }
        inputFocused = true
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding(
            get: { model.sessionID },
            set: { id in
                if let id { model.open(id) }
            }
        )) {
            Section("履歴") {
                ForEach(model.sessions) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name?.isEmpty == false ? session.name! : "新規チャット")
                            .lineLimit(1)
                        if let updatedAt = session.updatedAt {
                            Text(updatedAt, format: .relative(presentation: .named))
                                .zoomedFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(session.id)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
        .scrollContentBackground(.hidden)
        .overlay {
            if model.sessions.isEmpty {
                Text(model.sessionsError ?? "履歴はまだありません")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .zoomedFont(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        transcript
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .frame(minWidth: 380, minHeight: 420)
            .navigationTitle(currentTitle)
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
            TextField("メッセージ", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .zoomedFont(.body)
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit { model.send() }
                .padding(.horizontal, 6)
                .padding(.top, 4)

            HStack(spacing: 8) {
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
        .disabled(!model.isRunning && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help(model.isRunning ? "停止" : "送信")
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
