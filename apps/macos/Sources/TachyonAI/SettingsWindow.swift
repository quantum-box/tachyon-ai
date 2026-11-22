import AppKit
import ServiceManagement
import SwiftUI

/// The settings window. Created once and shown again when reopened.
@MainActor
final class SettingsWindowController {
    private let model: ChatModel
    private var window: NSWindow?

    init(model: ChatModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            hosting.sceneBridgingOptions = [.toolbars, .title]
            hosting.sizingOptions = []

            let size = NSSize(width: 780, height: 600)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false)
            window.contentViewController = hosting
            window.toolbarStyle = .unified
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 640, height: 420)
            window.setContentSize(size)
            window.center()
            window.setFrameAutosaveName("SettingsSplit")
            self.window = window
        }
        window?.bringToFront()
        Task { await model.refreshModels() }
    }
}

/// The sections of the settings window, listed in the sidebar like System Settings.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case dictation
    case vocabulary
    case background
    case models

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "一般"
        case .dictation: return "音声入力"
        case .vocabulary: return "用語辞書"
        case .background: return "背景情報"
        case .models: return "モデル"
        }
    }

    var summary: String {
        switch self {
        case .general: return "アプリの起動のしかたを設定します。"
        case .dictation: return "fn キーを押している間の音声を文字にして、入力中のアプリに貼り付けます。"
        case .vocabulary: return "文字起こしで決まって間違う語を登録します。貼り付ける前に置き換えます。"
        case .background: return "あなたの仕事や使う言葉を書いておくと、聞き間違いを文脈から直します。"
        case .models: return "チャットのモデルメニューに表示するモデルを選びます。"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .dictation: return "mic.fill"
        case .vocabulary: return "character.book.closed.fill"
        case .background: return "person.text.rectangle.fill"
        case .models: return "sparkles"
        }
    }

    var color: Color {
        switch self {
        case .general: return .gray
        case .dictation: return .red
        case .vocabulary: return .orange
        case .background: return .blue
        case .models: return .purple
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: ChatModel
    @State private var pane: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    PaneIcon(pane: pane, size: 22)
                }
                .padding(.vertical, 2)
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            let pane = pane ?? .general
            Form {
                Section {
                    PaneHeader(pane: pane)
                }
                switch pane {
                case .general: GeneralPane()
                case .dictation: DictationPane()
                case .vocabulary: VocabularyPane()
                case .background: BackgroundPane()
                case .models: ModelsPane(model: model)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
    }
}

/// The rounded, coloured icon tile System Settings uses for each section.
private struct PaneIcon: View {
    let pane: SettingsPane
    let size: CGFloat

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: size * 0.56, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(pane.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

private struct PaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        VStack(spacing: 8) {
            PaneIcon(pane: pane, size: 56)
            Text(pane.title).font(.title2.weight(.bold))
            Text(pane.summary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var failure: String?

    var body: some View {
        Section {
            Toggle("ログイン時に起動", isOn: Binding(
                get: { launchAtLogin },
                set: { enable in
                    do {
                        if enable {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        failure = nil
                    } catch {
                        failure = error.localizedDescription
                    }
                    // Show what the system actually did, not what was asked for.
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
        } footer: {
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
    }
}

private struct DictationPane: View {
    @ObservedObject private var stats = DictationStats.shared
    @AppStorage(Preferences.cleanupModeKey) private var cleanupMode = CleanupMode.fast
    @AppStorage(Preferences.liveInsertKey) private var liveInsert = false

    var body: some View {
        Section {
            Picker("文字起こしの整形", selection: $cleanupMode) {
                ForEach(CleanupMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        } footer: {
            Text("高速: 「えーと」「あのー」などをアプリ内で即座に取り除きます。\n高精度: LLM が言い直しや句読点も直します。貼り付けが1〜数秒遅くなり、利用料がかかります。")
        }

        Section {
            Toggle("話しながら入力する (アルファ版)", isOn: $liveInsert)
                .disabled(cleanupMode == .thorough)
        } footer: {
            Text("試験的な機能です。オンにすると、文字起こしが届くそばから入力欄に打ち込みます。オフでは、fn を離したあとにまとめて貼り付けます。整形が「高精度」のときは使えません。")
        }

        if let last = stats.last {
            Section {
                LabeledContent("前回の所要時間", value: Self.describe(last))
            }
        }
    }

    private static func describe(_ timing: DictationStats.Timing) -> String {
        let transcription = String(format: "文字起こし %.1f秒", timing.transcription)
        guard let cleanup = timing.cleanup else { return transcription }
        return transcription + String(format: " + 整形 %.1f秒", cleanup)
    }
}

private struct VocabularyPane: View {
    @ObservedObject private var vocabulary = Vocabulary.shared

    var body: some View {
        Section {
            ForEach($vocabulary.entries) { $entry in
                HStack {
                    TextField("聞こえ方", text: $entry.heard, prompt: Text("聞こえ方 (例: タキオン)"))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("表記", text: $entry.written, prompt: Text("表記 (例: Tachyon)"))
                    Button {
                        vocabulary.entries.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("削除")
                }
                .labelsHidden()
            }
            Button {
                vocabulary.entries.append(Vocabulary.Entry(heard: "", written: ""))
            } label: {
                Label("語を追加", systemImage: "plus")
            }
        } footer: {
            Text("どの整形モードでも有効です。")
        }
    }
}

private struct BackgroundPane: View {
    @ObservedObject private var vocabulary = Vocabulary.shared

    var body: some View {
        Section {
            TextEditor(text: $vocabulary.background)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 160)
        } footer: {
            Text("職種、扱っている製品、よく使う専門用語などを書きます。整形が「高精度」のときだけ使われます。")
        }
    }
}

private struct ModelsPane: View {
    @ObservedObject var model: ChatModel

    var body: some View {
        if model.models.isEmpty {
            Section {
                Text("モデルを取得できませんでした。ログイン状態を確認してください。")
                    .foregroundStyle(.secondary)
            }
        }

        ForEach(model.providers, id: \.self) { provider in
            let offered = model.models.filter { $0.provider == provider }
            Section {
                ForEach(offered) { info in
                    Toggle(info.name, isOn: Binding(
                        get: { model.isEnabled(info) },
                        set: { model.setEnabled($0, for: [info]) }))
                }
            } header: {
                HStack {
                    Text(provider)
                    Spacer()
                    // One switch for the whole provider.
                    let allOn = offered.allSatisfy(model.isEnabled)
                    Button(allOn ? "すべてオフ" : "すべてオン") {
                        model.setEnabled(!allOn, for: offered)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }

        Section {
            Button("既定に戻す (GPT-6 のみ)") {
                model.resetEnabledModels()
            }
        }
    }
}
