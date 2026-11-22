import SwiftUI

struct SettingsScreen: View {
    @ObservedObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    private var gemmaStatus: String {
        switch store.gemma.state {
        case .missing: "未ダウンロード"
        case .downloading(let fraction): "ダウンロード中 \(Int(fraction * 100))%"
        case .ready: "保存済み (\(GemmaDownload.displaySize))"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("AI への指示", text: $store.instructions, axis: .vertical)
                        .lineLimit(3...10)
                    Button("初期設定に戻す") {
                        store.instructions = ChatStore.defaultInstructions
                    }
                    .disabled(store.instructions == ChatStore.defaultInstructions)
                } header: {
                    Text("AI への指示")
                } footer: {
                    Text("口調や答え方を決めます。次に送るメッセージから反映されます。")
                }

                Section {
                    LabeledContent("モデルファイル", value: gemmaStatus)
                    Button("モデルファイルを削除", role: .destructive) {
                        store.deleteGemma()
                    }
                    .disabled(store.gemma.state == .missing)
                } header: {
                    Text("Gemma 4")
                } footer: {
                    Text("削除すると \(GemmaDownload.displaySize) の空きが戻ります。もう一度使うときは再ダウンロードが必要です。")
                }

                Section {
                    Button("すべての履歴を削除", role: .destructive) {
                        confirmingDelete = true
                    }
                    .disabled(store.conversations.isEmpty)
                } footer: {
                    Text("会話はこのデバイスにだけ保存されています。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .confirmationDialog(
                "すべての履歴を削除しますか?", isPresented: $confirmingDelete, titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) { store.deleteAll() }
            } message: {
                Text("この操作は取り消せません。")
            }
        }
    }
}
