import AppKit
import SwiftUI

/// Creates or edits a project: its name, workspace folder and instructions.
struct ProjectEditor: View {
    @State var project: Project
    let onSave: (Project) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folderError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(project.name.isEmpty ? "新規プロジェクト" : project.name)
                .font(.title3.weight(.semibold))

            Form {
                TextField("名前", text: $project.name, prompt: Text("例: 社内ツール"))

                LabeledContent("フォルダ") {
                    HStack {
                        if let path = project.folderPath {
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path)
                            Button("外す") { project.clearFolder() }
                        } else {
                            Text("なし").foregroundStyle(.secondary)
                        }
                        Button("選ぶ…", action: chooseFolder)
                    }
                }
                if let folderError {
                    Text(folderError).foregroundStyle(.red).font(.callout)
                }
                Toggle("確認せずにファイルの書き込みを許可", isOn: $project.allowsWritesWithoutAsking)
                    .disabled(project.folderPath == nil)

                VStack(alignment: .leading, spacing: 4) {
                    Text("指示")
                    TextEditor(text: $project.instructions)
                        .font(.body)
                        .frame(minHeight: 110)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                    Text("このプロジェクトの会話では、毎回この指示をエージェントに渡します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.columns)

            Text("フォルダを選ぶと、エージェントがその中のファイルを一覧・検索・読み取りできます。書き込みは、上の設定をオンにしない限り毎回確認します。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if project.folderPath == nil { project.allowsWritesWithoutAsking = false }
                    onSave(project)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "このフォルダを使う"
        panel.message = "エージェントが作業するフォルダを選んでください。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try project.setFolder(url)
            folderError = nil
            if project.name.trimmingCharacters(in: .whitespaces).isEmpty {
                project.name = url.lastPathComponent
            }
        } catch {
            folderError = "フォルダを覚えられませんでした: \(error.localizedDescription)"
        }
    }
}
