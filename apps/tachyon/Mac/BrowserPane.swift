import AppKit
import SwiftUI
import WebKit

/// One tab of the side pane: a web page, or something from the chat shown in full.
@MainActor
final class BrowserTab: Identifiable {
    enum Content {
        case web(WebPage)
        /// A reply, rendered as Markdown, or a text file, shown as it is.
        case document(title: String, text: String, isMarkdown: Bool)
        case image(title: String, image: NSImage)
    }

    let id = UUID()
    let content: Content

    /// The page of a web tab.
    var page: WebPage? {
        if case .web(let page) = content { return page }
        return nil
    }

    var title: String {
        switch content {
        case .web(let page):
            if !page.title.isEmpty { return page.title }
            return page.url?.host() ?? "新しいタブ"
        case .document(let title, _, _), .image(let title, _):
            return title
        }
    }

    init(content: Content) {
        self.content = content
    }

    init(url: URL?, openInNewTab: @escaping @MainActor (URL) -> Void) {
        // The shared, persistent store: sign-ins (and cookies imported from Chrome) last.
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .default()
        // Without the Safari part, Google and others turn the page away as an old browser.
        configuration.applicationNameForUserAgent = Self.safariUserAgentSuffix
        let page = WebPage(configuration: configuration, navigationDecider: NewWindowDecider(openInNewTab: openInNewTab))
        if let url { _ = page.load(URLRequest(url: url)) }
        content = .web(page)
    }

    /// What Safari of this Mac puts after WebKit's part of the user agent.
    private static let safariUserAgentSuffix: String = {
        let version = Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }()
}

/// Links that ask for a new window (`target="_blank"`) open in a new tab instead.
private struct NewWindowDecider: WebPage.NavigationDeciding {
    let openInNewTab: @MainActor (URL) -> Void

    func decidePolicy(
        for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard action.target == nil, let url = action.request.url else { return .allow }
        openInNewTab(url)
        return .cancel
    }
}

/// The tabs of the browser pane beside the chat. Each conversation keeps its own
/// tabs: switching conversations swaps them, and they come back after a relaunch.
@MainActor
final class BrowserPaneModel: ObservableObject {
    @Published var isShown = Preferences.browserPaneShown {
        didSet { Preferences.browserPaneShown = isShown }
    }
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedTabID: BrowserTab.ID?
    /// Bumped to move keyboard focus to the open web tab's address field (⌘L).
    @Published private(set) var addressFocusRequest = 0

    /// The conversation the tabs belong to; nil for a new chat not sent yet.
    private var sessionID: String?
    /// Tabs of the other conversations opened in this run, kept alive so switching back
    /// keeps reply and file tabs, page history and half-typed forms. Saved URLs are only
    /// for after a relaunch.
    private var liveTabs: [String: (tabs: [BrowserTab], selected: BrowserTab.ID?)] = [:]

    private struct SavedTabs: Codable {
        var urls: [URL]
        var selected: Int?
    }

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// Shows the tabs of `id`. When a new chat gets its ID on the first send,
    /// `adopting` keeps the tabs already open: they belong to that chat now.
    func show(session id: String?, adopting: Bool = false) {
        if adopting, sessionID == nil, let id {
            sessionID = id
            save()
            return
        }
        guard id != sessionID else { return }
        save()
        // A new chat that was never sent has nowhere to come back to, so its tabs go.
        if let current = sessionID {
            liveTabs[current] = (tabs, selectedTabID)
        }
        sessionID = id
        if let id, let live = liveTabs.removeValue(forKey: id) {
            tabs = live.tabs
            selectedTabID = live.selected
            return
        }
        let saved = id.flatMap { Self.loadAll()[$0] }
        tabs = saved?.urls.map(makeTab) ?? []
        let selected = saved?.selected.flatMap { tabs.indices.contains($0) ? $0 : nil }
        selectedTabID = selected.map { tabs[$0].id } ?? tabs.first?.id
    }

    /// Opens `url` in a new tab and brings it to the front.
    func open(_ url: URL) {
        let tab = makeTab(url)
        insert(tab)
    }

    /// An empty tab, for typing an address.
    func newTab() {
        insert(makeTab(nil))
    }

    /// ⌘L: the address field of the open web tab, or a new tab when none is open.
    func focusAddressBar() {
        guard selectedTab?.page != nil else {
            newTab()
            return
        }
        isShown = true
        addressFocusRequest += 1
    }

    /// Shows text from the chat in full. Such tabs last until the app quits.
    func openDocument(title: String, text: String, isMarkdown: Bool) {
        insert(BrowserTab(content: .document(title: title, text: text, isMarkdown: isMarkdown)))
    }

    /// Shows an attachment: images as they are, text files as text.
    func open(_ attachment: Attachment) {
        if attachment.isImage {
            guard let image = NSImage(data: attachment.data) else { return }
            insert(BrowserTab(content: .image(title: attachment.filename, image: image)))
        } else {
            let text = String(decoding: attachment.data, as: UTF8.self)
            let isMarkdown = ["md", "markdown"].contains((attachment.filename as NSString).pathExtension.lowercased())
            openDocument(title: attachment.filename, text: text, isMarkdown: isMarkdown)
        }
    }

    /// The selected tab's page as text for the agent: nil when no web page is open.
    /// URL, title and text come from one evaluation, so they describe the same document
    /// even if the tab navigates meanwhile: the URL decides whether the user is asked.
    func selectedPageText(limit: Int = 60_000) async -> (title: String, url: URL, text: String)? {
        guard let page = selectedTab?.page, page.url != nil else { return nil }
        let snapshot = try? await page.callJavaScript("""
            return { url: location.href, title: document.title,
                     text: document.body ? document.body.innerText : "" };
            """) as? [String: Any]
        guard let snapshot, let url = (snapshot["url"] as? String).flatMap(URL.init(string:)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let text = snapshot["text"] as? String ?? ""
        let clipped = text.count > limit ? String(text.prefix(limit)) + "\n…(以下省略)" : text
        return (snapshot["title"] as? String ?? "", url, clipped)
    }

    func close(_ id: BrowserTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].page?.stopLoading()
        tabs.remove(at: index)
        if selectedTabID == id {
            let next = tabs.indices.contains(index) ? index : tabs.index(before: index)
            selectedTabID = tabs.indices.contains(next) ? tabs[next].id : nil
        }
        save()
    }

    /// Writes the open conversation's tabs. Called whenever a tab's address changes.
    func save() {
        guard let sessionID else { return }
        var all = Self.loadAll()
        // Only web pages come back; empty tabs and chat content do not.
        let open = tabs.filter { $0.page?.url != nil }
        if open.isEmpty {
            all[sessionID] = nil
        } else {
            all[sessionID] = SavedTabs(
                urls: open.compactMap { $0.page?.url },
                selected: open.firstIndex { $0.id == selectedTabID })
        }
        Preferences.browserTabs = try? JSONEncoder().encode(all)
    }

    private func insert(_ tab: BrowserTab) {
        let index = tabs.firstIndex { $0.id == selectedTabID }.map { $0 + 1 } ?? tabs.endIndex
        tabs.insert(tab, at: index)
        selectedTabID = tab.id
        isShown = true
        save()
    }

    private func makeTab(_ url: URL?) -> BrowserTab {
        BrowserTab(url: url) { [weak self] in self?.open($0) }
    }

    private static func loadAll() -> [String: SavedTabs] {
        guard let data = Preferences.browserTabs else { return [:] }
        return (try? JSONDecoder().decode([String: SavedTabs].self, from: data)) ?? [:]
    }
}

// MARK: - Views

/// The tab strip and the selected page.
struct BrowserPane: View {
    @ObservedObject var pane: BrowserPaneModel
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            if let tab = pane.selectedTab {
                switch tab.content {
                case .web(let page):
                    BrowserTabView(page: page, pane: pane)
                        .id(tab.id)
                case .document(_, let text, let isMarkdown):
                    DocumentView(text: text, isMarkdown: isMarkdown)
                        .id(tab.id)
                case .image(_, let image):
                    ImageTabView(image: image)
                        .id(tab.id)
                }
            } else {
                ContentUnavailableView {
                    Label("タブがありません", systemImage: "globe")
                } description: {
                    Text("チャットのリンクを開くか、＋で新しいタブを開いてください。")
                } actions: {
                    Button("新しいタブ") { pane.newTab() }
                }
                .frame(maxHeight: .infinity)
            }
        }
        // Keeps the tab strip at the top even when there is no page to fill the pane.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(pane.tabs) { tab in
                        TabChip(
                            tab: tab,
                            isSelected: tab.id == pane.selectedTabID,
                            select: {
                                pane.selectedTabID = tab.id
                                pane.save()
                            },
                            close: { pane.close(tab.id) })
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)

            Button(action: pane.newTab) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("新しいタブ (⌘T)")

            Menu {
                // Signed in with the pane's own login, which does not share the app's.
                ForEach(Settings.load().sites, id: \.self) { site in
                    Button("\(site.name) を開く") { pane.open(site.url) }
                }
                Divider()
                // Read when the menu opens, so the count is current.
                let hosts = Preferences.sharedPageHosts
                Button(hosts.isEmpty
                       ? "ページの読み取りを常に許可したサイトはありません"
                       : "ページの読み取りの常に許可を解除 (\(hosts.count) サイト)") {
                    Preferences.sharedPageHosts = []
                }
                .disabled(hosts.isEmpty)
                Divider()
                Button("Chrome からログイン状態を読み込む…") { importing = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("その他")
            .padding(.trailing, 10)
        }
        .frame(height: 34)
        .sheet(isPresented: $importing) {
            ChromeImportSheet {
                if let page = pane.selectedTab?.page, page.url != nil { _ = page.reload() }
            }
        }
    }
}

private struct TabChip: View {
    let tab: BrowserTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            // Reading the page's title here keeps the chip in step with it.
            Text(tab.title)
                .lineLimit(1)
                .font(.callout)
                .frame(maxWidth: 140, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .opacity(isSelected || isHovering ? 1 : 0)
            .help("タブを閉じる")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(isSelected ? Color.primary.opacity(0.1) : Color.clear))
        .contentShape(Capsule())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help(tab.page?.url?.absoluteString ?? tab.title)
    }

    private var icon: String {
        switch tab.content {
        case .web: return "globe"
        case .document(_, _, true): return "doc.richtext"
        case .document: return "doc.plaintext"
        case .image: return "photo"
        }
    }
}

/// A reply or text file in full, with a button to copy it.
private struct DocumentView: View {
    let text: String
    let isMarkdown: Bool

    var body: some View {
        ScrollView {
            Group {
                if isMarkdown {
                    MarkdownView(text)
                } else {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("コピー")
            .padding(10)
        }
    }
}

private struct ImageTabView: View {
    let image: NSImage

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                .padding(16)
        }
    }
}

private struct BrowserTabView: View {
    let page: WebPage
    @ObservedObject var pane: BrowserPaneModel
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            ZStack(alignment: .top) {
                if page.url == nil, !page.isLoading {
                    Color.clear
                } else {
                    // The web view fills what it is given and its own size never reaches
                    // the window's layout: a page that kept changing it (Field, opened while
                    // a reply streamed in) looped AppKit's constraint passes and crashed.
                    Color.clear
                        .overlay { WebView(page) }
                        .clipped()
                }
                if page.isLoading {
                    ProgressView(value: page.estimatedProgress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                }
            }
        }
        .onAppear {
            address = page.url?.absoluteString ?? ""
            if page.url == nil { addressFocused = true }
        }
        .onChange(of: pane.addressFocusRequest) {
            addressFocused = true
        }
        .onChange(of: page.url) {
            if !addressFocused { address = page.url?.absoluteString ?? "" }
            pane.save()
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 6) {
            Button {
                if let item = page.backForwardList.backList.last { _ = page.load(item) }
            } label: { Image(systemName: "chevron.left") }
                .disabled(page.backForwardList.backList.isEmpty)
                .help("戻る")
            Button {
                if let item = page.backForwardList.forwardList.first { _ = page.load(item) }
            } label: { Image(systemName: "chevron.right") }
                .disabled(page.backForwardList.forwardList.isEmpty)
                .help("進む")
            Button {
                if page.isLoading { page.stopLoading() } else { _ = page.reload() }
            } label: { Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise") }
                .disabled(page.url == nil)
                .help(page.isLoading ? "読み込みを中止" : "再読み込み")

            TextField("URL または検索語", text: $address)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit(go)

            Button {
                if let url = page.url { NSWorkspace.shared.open(url) }
            } label: { Image(systemName: "safari") }
                .disabled(page.url == nil)
                .help("ブラウザで開く")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func go() {
        guard let url = Self.url(from: address) else { return }
        addressFocused = false
        _ = page.load(URLRequest(url: url))
    }

    /// An address as typed: a URL (scheme optional) or, failing that, a web search.
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            return url
        }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text), url.host() != nil {
            return url
        }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }
}
