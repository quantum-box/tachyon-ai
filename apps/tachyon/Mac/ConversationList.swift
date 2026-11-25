import SwiftUI

/// The chat window's sidebar: pinned conversations, one section per project, then the
/// rest. Right-click a conversation to pin, rename or delete it.
struct ConversationList: View {
    @ObservedObject var model: ChatModel
    /// Starts a new chat in a project (nil: none) and focuses the message field.
    let startNewChat: (String?) -> Void

    @State private var search = ""
    @State private var renaming: SessionSummary?
    @State private var newName = ""
    @State private var deleting: SessionSummary?
    @State private var editingProject: Project?
    @State private var deletingProject: Project?

    var body: some View {
        List(selection: Binding(
            get: { model.sessionID },
            set: { id in
                if let id { model.open(id) }
            }
        )) {
            if !pinned.isEmpty {
                Section("ピン留め") { rows(pinned) }
            }
            ForEach(model.projects) { project in
                Section {
                    rows(unpinned.filter { $0.projectID == project.id })
                } header: {
                    projectHeader(project)
                }
            }
            Section("履歴") {
                rows(unpinned.filter { $0.projectID.flatMap(model.project) == nil })
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "会話を検索")
        .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
        .scrollContentBackground(.hidden)
        .overlay {
            if model.sessions.isEmpty {
                Text(model.sessionsError ?? "履歴はまだありません")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .zoomedFont(.callout)
                    .foregroundStyle(.secondary)
            } else if !search.isEmpty, visible.isEmpty {
                Text("「\(search)」に一致する会話はありません")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .zoomedFont(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                editingProject = Project(name: "")
            } label: {
                Label("新規プロジェクト", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .sheet(item: $editingProject) { project in
            ProjectEditor(project: project) { saved in
                let isNew = model.project(saved.id) == nil
                model.saveProject(saved)
                if isNew { startNewChat(saved.id) }
            }
        }
        .alert("会話の名前を変更", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("名前", text: $newName)
            Button("変更") {
                if let session = renaming {
                    Task { await model.rename(session.id, to: newName) }
                }
                renaming = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("キャンセル", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "「\(deleting.map(title) ?? "")」を削除しますか？",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                if let session = deleting {
                    Task { await model.delete(session.id) }
                }
                deleting = nil
            }
            Button("キャンセル", role: .cancel) { deleting = nil }
        } message: {
            Text("会話とメッセージはサーバーから消え、元に戻せません。iPhone の一覧からも消えます。")
        }
        .confirmationDialog(
            "プロジェクト「\(deletingProject?.name ?? "")」を削除しますか？",
            isPresented: Binding(get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } }),
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                if let project = deletingProject { model.deleteProject(project.id) }
                deletingProject = nil
            }
            Button("キャンセル", role: .cancel) { deletingProject = nil }
        } message: {
            Text("プロジェクトの設定だけを消します。会話は消えずに「履歴」へ移り、フォルダの中身もそのままです。")
        }
        .alert(
            "操作できませんでした",
            isPresented: Binding(get: { model.sessionActionError != nil }, set: { if !$0 { model.sessionActionError = nil } }),
            presenting: model.sessionActionError
        ) { _ in
            Button("OK") { model.sessionActionError = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Lists

    /// The conversations the search matches (all of them while it is empty).
    private var visible: [SessionSummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.sessions }
        return model.sessions.filter { title($0).localizedCaseInsensitiveContains(query) }
    }

    /// In the order they were pinned.
    private var pinned: [SessionSummary] {
        let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return model.pinnedSessionIDs.compactMap { byID[$0] }
    }

    private var unpinned: [SessionSummary] {
        visible.filter { !model.isPinned($0.id) }
    }

    private func title(_ session: SessionSummary) -> String {
        session.name?.isEmpty == false ? session.name! : "新規チャット"
    }

    @ViewBuilder
    private func rows(_ sessions: [SessionSummary]) -> some View {
        ForEach(sessions) { session in
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if model.isPinned(session.id) {
                        Image(systemName: "pin.fill")
                            .zoomedFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(title(session)).lineLimit(1)
                }
                if let updatedAt = session.updatedAt {
                    Text(updatedAt, format: .relative(presentation: .named))
                        .zoomedFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .tag(session.id)
            .contextMenu { menu(for: session) }
        }
    }

    @ViewBuilder
    private func menu(for session: SessionSummary) -> some View {
        Button(model.isPinned(session.id) ? "ピン留めを外す" : "ピン留め") {
            withAnimation { model.togglePin(session.id) }
        }
        Button("名前を変更…") {
            newName = session.name ?? ""
            renaming = session
        }
        Divider()
        Button("削除…", role: .destructive) { deleting = session }
    }

    private func projectHeader(_ project: Project) -> some View {
        HStack(spacing: 6) {
            Image(systemName: project.folderPath == nil ? "folder" : "folder.fill")
            Text(project.name).lineLimit(1)
            Spacer(minLength: 0)
            Button {
                startNewChat(project.id)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("このプロジェクトで新規チャット")
            Menu {
                Button("このプロジェクトで新規チャット") { startNewChat(project.id) }
                Button("プロジェクトを編集…") { editingProject = project }
                Divider()
                Button("プロジェクトを削除…", role: .destructive) { deletingProject = project }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .help(project.folderPath ?? project.name)
        .contextMenu {
            Button("このプロジェクトで新規チャット") { startNewChat(project.id) }
            Button("プロジェクトを編集…") { editingProject = project }
            Divider()
            Button("プロジェクトを削除…", role: .destructive) { deletingProject = project }
        }
    }
}
