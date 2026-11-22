import FoundationModels
import SwiftUI

/// Conversation list and the open conversation. On iPhone the two are stacked;
/// on iPad they sit side by side.
struct ChatScreen: View {
    @ObservedObject var store: ChatStore

    @State private var column = NavigationSplitViewColumn.detail
    @State private var showingSettings = false
    @FocusState private var inputFocused: Bool
    @Environment(\.openURL) private var openURL

    private static let appName = "AIシンくん"
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
            SettingsScreen(store: store)
        }
    }

    private func startNewChat() {
        withAnimation(.bouncy) { store.startNewChat() }
        column = .detail
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding(
            get: { store.currentID },
            set: { id in
                guard let id else { return }
                store.open(id)
                column = .detail
            }
        )) {
            ForEach(store.conversations) { conversation in
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title).lineLimit(1)
                    Text(conversation.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(conversation.id)
                .swipeActions {
                    Button("削除", systemImage: "trash", role: .destructive) {
                        store.delete(conversation.id)
                    }
                }
            }
        }
        .navigationTitle("履歴")
        .scrollContentBackground(.hidden)
        .background { AppBackdrop() }
        .overlay {
            if store.conversations.isEmpty {
                ContentUnavailableView("履歴はまだありません", systemImage: "bubble.left.and.bubble.right")
            }
        }
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
            .navigationTitle(store.currentTitle ?? Self.appName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Drawn here because the bar keeps a stale title when another conversation is opened.
                ToolbarItem(placement: .principal) {
                    Text(store.currentTitle ?? Self.appName)
                        .font(.headline)
                        .lineLimit(1)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: startNewChat) {
                        Label("新規チャット", systemImage: "square.and.pencil")
                    }
                    .disabled(store.messages.isEmpty)
                }
            }
    }

    private var transcript: some View {
        ScrollView {
            // Bubbles share one container so the system can draw them together.
            // The spacing is below the gap between bubbles, so they never fuse.
            GlassEffectContainer(spacing: 6) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.messages.isEmpty {
                        welcome
                    }
                    ForEach(store.messages) { message in
                        MessageRow(message: message)
                    }
                    if store.isRunning, store.messages.last?.text.isEmpty == true {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("考えています…").font(.callout)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .glassEffect(.regular, in: .capsule)
                    }
                }
                .padding(16)
            }
            .animation(.bouncy(duration: 0.4), value: store.messages.count)
        }
        // A short conversation sits at the top; a long one follows the newest text.
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 84, height: 84)
                .glassEffect(.regular.interactive(), in: .circle)

            VStack(spacing: 6) {
                Text(Self.appName).font(.title2.weight(.semibold))
                Text("このデバイスの中だけで動く AI です。会話は外に送られません。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        store.draft = suggestion
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
            if !store.isReady {
                modelNotice
            }
            TextField("メッセージ", text: $store.draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($inputFocused)
                .padding(.horizontal, 4)
            HStack(spacing: 8) {
                modelMenu
                Spacer(minLength: 0)
                sendButton
            }
        }
        .padding(14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.top, 6)
        .animation(.bouncy(duration: 0.35), value: store.isRunning)
        .animation(.smooth(duration: 0.25), value: store.isReady)
        .task(id: store.isReady) {
            // Apple Intelligence can become ready while this screen is showing.
            while !store.isReady, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                store.refreshAvailability()
            }
        }
    }

    private var modelMenu: some View {
        Menu {
            Picker("モデル", selection: $store.choice) {
                ForEach(ModelChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.choice.title).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Model notice

    /// Says why the chosen model cannot answer yet and what fixes it.
    @ViewBuilder private var modelNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch store.choice {
            case .apple:
                if case .unavailable(let reason) = store.availability {
                    Label(Self.title(for: reason), systemImage: "apple.intelligence")
                        .font(.subheadline.weight(.semibold))
                    Text(Self.detail(for: reason))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if reason == .appleIntelligenceNotEnabled {
                            Button("設定を開く") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(url)
                                }
                            }
                        }
                        Button("Gemma 4 を使う") { store.choice = .gemma }
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .font(.footnote.weight(.medium))
                }
            case .gemma:
                gemmaNotice
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    @ViewBuilder private var gemmaNotice: some View {
        switch store.gemma.state {
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("Gemma 4 をダウンロード中… \(Int(fraction * 100))%")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            Button("キャンセル") { store.gemma.cancel() }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .font(.footnote.weight(.medium))
        case .missing, .ready:
            Label("Gemma 4 のダウンロードが必要です", systemImage: "arrow.down.circle")
                .font(.subheadline.weight(.semibold))
            Text("モデル (\(GemmaDownload.displaySize)) をこのデバイスに保存します。Wi-Fi での利用をおすすめします。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let error = store.gemma.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button("ダウンロード") { store.gemma.start() }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .font(.footnote.weight(.medium))
        }
    }

    private static func title(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "このデバイスでは Apple Intelligence を使えません"
        case .appleIntelligenceNotEnabled: "Apple Intelligence がオフです"
        case .modelNotReady: "Apple Intelligence を準備中です"
        @unknown default: "Apple Intelligence をいまは使えません"
        }
    }

    private static func detail(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            "Apple Intelligence に対応したデバイスが必要です。"
        case .appleIntelligenceNotEnabled:
            "「設定」>「Apple Intelligence と Siri」でオンにしてください。"
        case .modelNotReady:
            "モデルをダウンロードしています。終わると自動で使えるようになります。"
        @unknown default:
            "しばらくしてからもう一度試してください。"
        }
    }

    private var sendButton: some View {
        Button {
            if store.isRunning {
                store.stop()
            } else {
                store.send()
                inputFocused = false
            }
        } label: {
            Image(systemName: store.isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(store.isRunning ? Color.red : Color.accentColor))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!store.isRunning
            && (!store.isReady || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        .accessibilityLabel(store.isRunning ? "停止" : "送信")
    }
}

/// One message in a conversation, drawn as a Liquid Glass bubble.
private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 56)
                Text(message.text)
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(.accentColor).interactive(), in: .rect(cornerRadius: 18))
            }
        case .assistant:
            // Empty until the first text arrives; the progress capsule stands in for it.
            if !message.text.isEmpty {
                HStack {
                    MarkdownView(message.text)
                        .foregroundStyle(message.failed ? Color.red : Color.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .glassEffect(
                            message.failed ? .regular.tint(.red.opacity(0.25)) : .regular,
                            in: .rect(cornerRadius: 18))
                    Spacer(minLength: 32)
                }
            }
        }
    }
}
