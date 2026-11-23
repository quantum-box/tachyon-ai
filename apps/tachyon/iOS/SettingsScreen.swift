import SwiftUI

/// Settings, presented as a sheet. The sections are the same ones the Mac app shows.
struct SettingsScreen: View {
    let app: AppState
    @ObservedObject var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Preferences.cleanupModeKey) private var cleanupMode = CleanupMode.fast

    var body: some View {
        NavigationStack {
            Form {
                TenantPane(account: app.account)

                Section {
                    Picker("文字起こしの整形", selection: $cleanupMode) {
                        ForEach(CleanupMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } header: {
                    Text("音声入力")
                } footer: {
                    Text("高速: 「えーと」「あのー」などをアプリ内で即座に取り除きます。\n高精度: LLM が言い直しや句読点も直します。少し遅くなり、利用料がかかります。")
                }

                NavigationLink("音声入力の履歴") {
                    Form { HistoryPane() }.navigationTitle("履歴")
                }
                NavigationLink("用語辞書") {
                    Form { VocabularyPane() }.navigationTitle("用語辞書")
                }
                NavigationLink("背景情報") {
                    Form { BackgroundPane() }.navigationTitle("背景情報")
                }
                NavigationLink("チャットのモデル") {
                    Form { ModelsPane(model: model) }.navigationTitle("モデル")
                }
                NavigationLink("使用量") {
                    Form { UsagePane(model: model) }.navigationTitle("使用量")
                }

                Section {
                    Button("ログアウト", role: .destructive) {
                        dismiss()
                        app.account.logout()
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .task { await model.refreshModels() }
        }
    }
}
