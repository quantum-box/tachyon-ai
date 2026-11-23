import AppKit
import ServiceManagement
import SwiftUI

/// The settings window. Created once and shown again when reopened.
@MainActor
final class SettingsWindowController {
    private let model: ChatModel
    private let account: Account
    private var window: NSWindow?

    init(model: ChatModel, account: Account) {
        self.model = model
        self.account = account
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model, account: account))
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
    case usage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "一般"
        case .dictation: return "音声入力"
        case .vocabulary: return "用語辞書"
        case .background: return "背景情報"
        case .models: return "モデル"
        case .usage: return "使用量"
        }
    }

    var summary: String {
        switch self {
        case .general: return "使うテナントと、アプリの起動のしかたを設定します。"
        case .dictation: return "fn キーを押している間の音声を文字にして、入力中のアプリに貼り付けます。"
        case .vocabulary: return "文字起こしで決まって間違う語を登録します。貼り付ける前に置き換えます。"
        case .background: return "あなたの仕事や使う言葉を書いておくと、聞き間違いを文脈から直します。"
        case .models: return "チャットのモデルメニューに表示するモデルを選びます。"
        case .usage: return "チャットで使ったトークン数と料金を確認します。"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .dictation: return "mic.fill"
        case .vocabulary: return "character.book.closed.fill"
        case .background: return "person.text.rectangle.fill"
        case .models: return "sparkles"
        case .usage: return "chart.bar.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: return .gray
        case .dictation: return .red
        case .vocabulary: return .orange
        case .background: return .blue
        case .models: return .purple
        case .usage: return .green
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: ChatModel
    let account: Account
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
                case .general:
                    TenantPane(account: account)
                    GeneralPane()
                case .dictation: DictationPane()
                case .vocabulary: VocabularyPane()
                case .background: BackgroundPane()
                case .models: ModelsPane(model: model)
                case .usage: UsagePane(model: model)
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
    @AppStorage(Preferences.dictationSoundsKey) private var sounds = true

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

        Section {
            Toggle("録音の開始と終了で音を鳴らす", isOn: $sounds)
        } footer: {
            Text("fn を押して録音が始まったときと、離したときに短い音を鳴らします。")
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
