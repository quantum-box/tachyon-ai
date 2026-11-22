import SwiftUI

// Settings sections used by both the Mac and the iOS app. Each is the content of a `Form`.

struct TenantPane: View {
    @ObservedObject var account: Account

    var body: some View {
        Section {
            Picker("テナント", selection: Binding(
                get: { account.tenantID ?? "" },
                set: { account.selectTenant($0) })) {
                ForEach(account.tenants) { tenant in
                    Text(tenant.name).tag(tenant.id)
                }
                // The current tenant before the list has loaded, or one no longer listed.
                if let current = account.tenantID, !account.tenants.contains(where: { $0.id == current }) {
                    Text(current).tag(current)
                }
            }
            .disabled(!account.canChooseTenant || account.tenants.count < 2)
        } footer: {
            Text(account.canChooseTenant
                ? "切り替えると、履歴と使えるモデルがそのテナントのものになります。"
                : "config.json の operatorId で固定されています。")
        }
        .task { await account.refreshTenants() }
    }
}

/// What has been used: the open conversation, and everything through this app.
struct UsagePane: View {
    @ObservedObject var model: ChatModel

    var body: some View {
        Section {
            LabeledContent("今の会話", value: model.transcript.usage?.summary ?? "—")
            LabeledContent("累計", value: model.totalUsage.totalTokens > 0 ? model.totalUsage.summary : "—")
        } footer: {
            Text("累計は、このアプリで受け取った返答の合計です。料金は API が金額を返したときだけ含まれます (米ドル)。")
        }

        Section {
            Button("累計をリセット", role: .destructive) {
                model.resetTotalUsage()
            }
            .disabled(model.totalUsage.totalTokens == 0)
        }
    }
}

struct VocabularyPane: View {
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

struct BackgroundPane: View {
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

struct ModelsPane: View {
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
