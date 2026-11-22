import AppKit
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
            hosting.sizingOptions = []

            let size = NSSize(width: 460, height: 560)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = "設定"
            window.contentViewController = hosting
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 380, height: 320)
            window.setContentSize(size)
            window.center()
            window.setFrameAutosaveName("Settings")
            self.window = window
        }
        window?.bringToFront()
        Task { await model.refreshModels() }
    }
}

/// Chooses which models appear in the chat's model menu.
private struct SettingsView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject private var stats = DictationStats.shared
    @ObservedObject private var vocabulary = Vocabulary.shared
    @AppStorage(Preferences.cleanupModeKey) private var cleanupMode = CleanupMode.fast
    @AppStorage(Preferences.liveInsertKey) private var liveInsert = false

    var body: some View {
        Form {
            Section("音声入力") {
                Toggle("話しながら入力する (アルファ版)", isOn: $liveInsert)
                    .disabled(cleanupMode == .thorough)
                Text("試験的な機能です。オンにすると、文字起こしが届くそばから入力欄に打ち込みます。オフ (既定) では、fn を離したあとにまとめて貼り付けます。整形が「高精度」のときは使えません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("文字起こしの整形", selection: $cleanupMode) {
                    ForEach(CleanupMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text("高速: 「えーと」「あのー」などをアプリ内で即座に取り除きます。\n高精度: LLM が言い直しや句読点も直します。貼り付けが1〜数秒遅くなり、利用料がかかります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let last = stats.last {
                    LabeledContent("前回の所要時間") {
                        Text(Self.describe(last))
                    }
                }
            }

            Section("用語辞書") {
                Text("文字起こしで決まって間違う語を登録します。貼り付け前に置き換えます (どの整形モードでも有効)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach($vocabulary.entries) { $entry in
                    HStack {
                        TextField("聞こえ方 (例: タキオン)", text: $entry.heard)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("表記 (例: Tachyon)", text: $entry.written)
                        Button {
                            vocabulary.entries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("削除")
                    }
                    .labelsHidden()
                }
                Button("語を追加") {
                    vocabulary.entries.append(Vocabulary.Entry(heard: "", written: ""))
                }
            }

            Section("背景情報") {
                Text("職種、扱っている製品、よく使う専門用語などを書いておくと、整形が「高精度」のときに聞き間違いを文脈から直します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $vocabulary.background)
                    .font(.body)
                    .frame(minHeight: 90)
            }

            Section("チャットのモデル") {
                Text("モデルメニューに表示するモデルを選びます。")
                    .foregroundStyle(.secondary)
            }

            if model.models.isEmpty {
                Section {
                    Text("モデルを取得できませんでした。ログイン状態を確認してください。")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(model.providers, id: \.self) { provider in
                Section {
                    ForEach(model.models.filter { $0.provider == provider }) { info in
                        Toggle(info.name, isOn: Binding(
                            get: { model.isEnabled(info) },
                            set: { model.setEnabled($0, for: [info]) }))
                    }
                } header: {
                    HStack {
                        Text(provider)
                        Spacer()
                        // One switch for the whole provider.
                        let all = model.models.filter { $0.provider == provider }
                        let allOn = all.allSatisfy(model.isEnabled)
                        Button(allOn ? "すべてオフ" : "すべてオン") {
                            model.setEnabled(!allOn, for: all)
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
        .formStyle(.grouped)
    }

    private static func describe(_ timing: DictationStats.Timing) -> String {
        let transcription = String(format: "文字起こし %.1f秒", timing.transcription)
        guard let cleanup = timing.cleanup else { return transcription }
        return transcription + String(format: " + 整形 %.1f秒", cleanup)
    }
}
