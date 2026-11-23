import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

/// Ties the fn key, microphone, transcription and paste together.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Shorter holds are treated as an accidental tap of fn.
    private static let minimumHold: TimeInterval = 0.25
    /// While speaking, this many characters at the end are held back: a filler can only
    /// be recognised (and dropped) once the characters after it are known.
    private static let liveHoldBack = 8
    /// Shorter transcripts ("はい", "OK") are not worth an LLM request.
    private static let minimumCleanupLength = 8

    private let model = OverlayModel()
    private let fnKey = FnKeyMonitor()
    private let corrections = CorrectionWatcher()
    private let audio = AudioCapture()
    private let auth = AuthService()
    private lazy var api = TachyonAPI(auth: auth)
    private lazy var account = Account(auth: auth)
    private lazy var chatModel = ChatModel(api: api)
    private lazy var chatWindow = ChatWindowController(model: chatModel, account: account) { [weak self] in
        self?.openSettingsWindow()
    }
    private lazy var settingsWindow = SettingsWindowController(model: chatModel, account: account)
    private var loginItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var cleanupItems: [CleanupMode: NSMenuItem] = [:]
    private var panel: OverlayPanel?
    private var statusItem: NSStatusItem?
    private var transcriber: RealtimeTranscriber?
    /// A connection opened ahead of time, so text starts arriving as soon as the key
    /// goes down instead of two to three seconds later. Idle time on it is not billed:
    /// transcription is charged by the length of the audio sent.
    private var standby: RealtimeTranscriber?
    private var standbyTimer: Timer?
    /// Types the transcript as it arrives; nil when the text is pasted once at the end.
    private var live: LiveInserter?
    private var pressedAt: Date?
    /// What the microphone delivered during the last recording, for the timing log.
    private var lastAudio = AudioCapture.Summary()
    private var errorDismissal: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = OverlayPanel(model: model)
        panel.orderFrontRegardless()
        self.panel = panel
        setUpStatusItem()
        setUpMainMenu()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)

        audio.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.model.level = level }
        }
        audio.onChunk = { [weak self] chunk in
            DispatchQueue.main.async { self?.transcriber?.append(chunk) }
        }

        fnKey.onPress = { [weak self] in self?.beginDictation() }
        fnKey.onRelease = { [weak self] in self?.endDictation() }
        fnKey.onCancel = { [weak self] in self?.cancelDictation() }
        fnKey.start()
        DictationSound.prepare()

        requestPermissions()
        account.onChange = { [weak self] in
            guard let self else { return }
            self.updateLoginItem()
            if self.account.isLoggedIn {
                self.prepareStandby()
            } else {
                // The conversation on screen belonged to the account that just signed out.
                self.chatModel.startNewChat()
            }
        }
        account.onTenantChange = { [weak self] in
            guard let self else { return }
            // History, models and the open connection all belong to the previous tenant.
            self.chatModel.startNewChat()
            self.standby?.cancel()
            self.standby = nil
            self.prepareStandby()
            Task {
                await self.chatModel.refreshSessions()
                await self.chatModel.refreshModels()
            }
        }
        // Signed out: show the window with its sign-in button, rather than opening
        // the sign-in page unasked.
        if !auth.isLoggedIn, Settings.load().apiKey == nil {
            chatWindow.show()
        }
        prepareStandby()
        standbyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prepareStandby() }
        }
        // `scripts/dev.sh` relaunches with this so the chat is back on screen after a rebuild.
        if CommandLine.arguments.contains("--chat") {
            chatWindow.show()
        }
    }

    /// Launching the app again while it is running (Dock, Spotlight, `open`) opens the chat.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        chatWindow.show()
        return true
    }

    // MARK: - Dictation

    private func beginDictation() {
        guard transcriber == nil else { return }
        errorDismissal?.cancel()
        // Whatever was fixed in the last dictation has been fixed by now.
        corrections.finish()

        do {
            try audio.start()
        } catch {
            show(error)
            return
        }
        DictationSound.start.play()

        let transcriber: RealtimeTranscriber
        // A connection set up before the vocabulary was edited would not know the new words.
        if let standby, standby.isUsable, standby.tuning == .dictation() {
            transcriber = standby
        } else {
            standby?.cancel()
            transcriber = makeTranscriber()
        }
        standby = nil
        transcriber.beginTurn()
        // The LLM cleanup rewrites the whole text, so it can only be pasted at the end.
        // Without permission to post events the keystrokes are dropped, so live typing
        // would lose the text. This is its own permission: Accessibility can be granted
        // while this one is still refused (a grant left over from a differently signed build).
        let live = Preferences.liveInsert && Preferences.cleanupMode != .thorough && CGPreflightPostEventAccess()
            ? LiveInserter() : nil
        self.live = live
        transcriber.onPartial = { [weak self] text in
            guard let self else { return }
            if let live {
                live.extend(to: String(Self.tidied(text).dropLast(Self.liveHoldBack)))
            } else {
                self.model.text = text
            }
        }
        transcriber.onSettled = { [weak self] metrics in
            DictationStats.shared.log(metrics, audio: self?.lastAudio ?? AudioCapture.Summary(), liveInsert: live != nil)
        }
        self.transcriber = transcriber

        pressedAt = Date()
        model.text = ""
        model.level = 0
        model.phase = .recording
        panel?.reposition()
    }

    private func makeTranscriber() -> RealtimeTranscriber {
        let auth = self.auth
        let transcriber = RealtimeTranscriber(loadConfig: { try await auth.config() }, tuning: .dictation())
        transcriber.start()
        return transcriber
    }

    /// Keeps one connection ready. Called at launch, after each dictation and on a timer,
    /// which replaces a connection that was dropped or has grown old.
    private func prepareStandby() {
        guard auth.isLoggedIn || Settings.load().apiKey != nil else { return }
        // A connection that does not know a word learned since is replaced ahead of the next press.
        if let standby, standby.isUsable, standby.tuning == .dictation() { return }
        standby?.cancel()
        standby = makeTranscriber()
    }

    /// The transcript as it should be typed in the current (non-LLM) cleanup mode.
    /// The user's own word replacements apply in every mode.
    private static func tidied(_ raw: String) -> String {
        let text = Preferences.cleanupMode == .off
            ? raw.trimmingCharacters(in: .whitespacesAndNewlines)
            : TranscriptCleaner.clean(raw)
        return Vocabulary.shared.apply(to: text)
    }

    private func endDictation() {
        guard let transcriber, let pressedAt else { return }
        // Once the microphone has closed, so the cue is never part of the recording.
        lastAudio = audio.stop { DictationSound.end.play() }
        guard Date().timeIntervalSince(pressedAt) >= Self.minimumHold else {
            cancelDictation()
            return
        }
        self.pressedAt = nil
        let live = self.live
        // When typing live, nearly everything is already in place: no "loading" state.
        model.phase = live == nil ? .transcribing : .idle

        // Let the last audio chunks queued on the main thread reach the transcriber first.
        let released = Date()
        DispatchQueue.main.async {
            Task { @MainActor in
                do {
                    let raw = try await transcriber.finish()
                    let transcribed = Date()
                    if let live {
                        // The confirmed text can differ slightly from what was streamed;
                        // if it no longer lines up with what was typed, finish from the stream.
                        if !live.extend(to: Self.tidied(raw)),
                           !live.extend(to: Self.tidied(transcriber.streamedText)) {
                            live.appendRemainder(of: Self.tidied(raw))
                        }
                        live.finish()
                        self.pasted(live.text)
                        DictationStats.shared.last = DictationStats.Timing(
                            transcription: transcribed.timeIntervalSince(released), cleanup: nil)
                        self.finishDictation(transcriber)
                        return
                    }
                    let (text, usedLLM) = await self.cleanedUp(raw)
                    DictationStats.shared.last = DictationStats.Timing(
                        transcription: transcribed.timeIntervalSince(released),
                        cleanup: usedLLM ? Date().timeIntervalSince(transcribed) : nil)
                    self.finishDictation(transcriber)
                    if !text.isEmpty, !CGPreflightPostEventAccess() {
                        // macOS drops the ⌘V without Accessibility. Keep the text on the
                        // clipboard and say why, instead of silently pasting nothing.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        DictationHistory.shared.add(text)
                        self.show(PermissionError.accessibilityForPaste)
                        return
                    }
                    if !text.isEmpty {
                        TextInserter.insert(text)
                        self.pasted(text)
                    }
                    // Nothing to paste because nothing was heard: say so instead of failing quietly.
                    if self.lastAudio.wasSilent {
                        self.show(DictationError.silentMicrophone)
                    }
                } catch {
                    live?.finish()
                    self.finishDictation(transcriber)
                    self.show(error)
                }
            }
        }
    }

    /// Tidies the transcript in the chosen mode. A failed LLM request falls back to the
    /// in-app cleanup: losing what was said is worse than pasting it less tidy.
    private func cleanedUp(_ raw: String) async -> (text: String, usedLLM: Bool) {
        switch Preferences.cleanupMode {
        case .off, .fast:
            return (Self.tidied(raw), false)
        case .thorough:
            guard raw.count >= Self.minimumCleanupLength else { return (Self.fallback(raw), false) }
            model.text = raw
            let vocabulary = Vocabulary.shared
            do {
                let cleaned = try await api.cleanUp(
                    transcript: raw,
                    background: vocabulary.background,
                    terms: vocabulary.replacements.map(\.written))
                // A reply far longer than the input is the model answering, not tidying.
                guard !cleaned.isEmpty, cleaned.count <= raw.count * 2 + 20 else {
                    return (Self.fallback(raw), true)
                }
                return (vocabulary.apply(to: cleaned), true)
            } catch {
                NSLog("TachyonAI: LLM cleanup failed: %@", error.localizedDescription)
                return (Self.fallback(raw), true)
            }
        }
    }

    /// From here on, the user fixing a word in `text` teaches the vocabulary that word.
    private func pasted(_ text: String) {
        DictationHistory.shared.add(text)
        Vocabulary.shared.noteDictated(text)
        corrections.begin(pasted: text)
    }

    /// What the thorough mode pastes when the LLM cannot be used.
    private static func fallback(_ raw: String) -> String {
        Vocabulary.shared.apply(to: TranscriptCleaner.clean(raw))
    }

    private func cancelDictation() {
        guard let transcriber else { return }
        audio.stop()
        transcriber.cancel()
        live?.finish()
        finishDictation(transcriber)
    }

    private func finishDictation(_ finished: RealtimeTranscriber) {
        guard transcriber === finished else { return }
        transcriber = nil
        live = nil
        pressedAt = nil
        model.phase = .idle
        model.text = ""
        prepareStandby()
    }

    private func show(_ error: Error) {
        NSLog("TachyonAI: %@", error.localizedDescription)
        model.phase = .error(error.localizedDescription)
        let dismissal = DispatchWorkItem { [weak self] in
            guard let self, case .error = self.model.phase else { return }
            self.model.phase = .idle
        }
        errorDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: dismissal)
    }

    // MARK: - Permissions

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // Needed to see the fn key in other apps and to send the paste keystroke.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(prompt) {
            show(PermissionError.accessibility)
        } else if !CGPreflightPostEventAccess() {
            // Asks again for the paste keystroke alone.
            CGRequestPostEventAccess()
        }
    }

    private enum DictationError: LocalizedError {
        case silentMicrophone
        var errorDescription: String? { "マイクから音が届いていません (ミュートになっていないか確認してください)" }
    }

    private enum PermissionError: LocalizedError {
        case accessibility
        case accessibilityForPaste
        var errorDescription: String? {
            switch self {
            case .accessibility: return "アクセシビリティを許可して、アプリを再起動してください"
            case .accessibilityForPaste:
                return "アクセシビリティが許可されていないため貼り付けられません (文字はクリップボードにあります)"
            }
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Tachyon AI")

        let menu = NSMenu()
        menu.addItem(withTitle: "チャットを開く", action: #selector(openChat), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "設定…", action: #selector(openSettingsWindow), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "音声入力の履歴…", action: #selector(openHistory), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "fn を押している間、音声入力", action: nil, keyEquivalent: "")
        let loginItem = menu.addItem(withTitle: "", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        self.loginItem = loginItem
        menu.addItem(.separator())
        let cleanupMenu = NSMenu()
        for mode in CleanupMode.allCases {
            let item = cleanupMenu.addItem(withTitle: mode.title, action: #selector(selectCleanupMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            cleanupItems[mode] = item
        }
        menu.addItem(withTitle: "文字起こしの整形", action: nil, keyEquivalent: "").submenu = cleanupMenu
        let launchAtLoginItem = menu.addItem(
            withTitle: "ログイン時に起動", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        self.launchAtLoginItem = launchAtLoginItem
        menu.delegate = self
        menuNeedsUpdate(menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "アクセシビリティ設定を開く…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "マイク設定を開く…", action: #selector(openMicrophoneSettings), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    /// Back to a menu-bar-only app once the chat and settings windows are all closed.
    @objc private func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing.styleMask.contains(.titled) else { return }
        let othersOpen = NSApp.windows.contains {
            $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel)
        }
        if !othersOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func zoomIn() { chatModel.zoomIn() }
    @objc private func zoomOut() { chatModel.zoomOut() }
    @objc private func resetZoom() { chatModel.resetZoom() }

    @objc private func openChat() {
        chatWindow.show()
    }

    @objc private func openSettingsWindow() {
        settingsWindow.show()
    }

    @objc private func openHistory() {
        settingsWindow.showHistory()
    }

    /// Never shown (the app has no menu bar of its own), but it is what makes
    /// ⌘C / ⌘V / ⌘A / ⌘W work in the chat window.
    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "設定…", action: #selector(openSettingsWindow), keyEquivalent: ",")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Tachyon AI を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, to: mainMenu)

        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(editMenu, to: mainMenu)

        let viewMenu = NSMenu(title: "表示")
        viewMenu.addItem(withTitle: "拡大", action: #selector(zoomIn), keyEquivalent: "+").target = self
        // ⌘= is the same key as ⌘+ without Shift on most keyboards.
        let zoomInUnshifted = viewMenu.addItem(withTitle: "拡大", action: #selector(zoomIn), keyEquivalent: "=")
        zoomInUnshifted.target = self
        zoomInUnshifted.isHidden = true
        zoomInUnshifted.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(withTitle: "縮小", action: #selector(zoomOut), keyEquivalent: "-").target = self
        viewMenu.addItem(withTitle: "実際のサイズ", action: #selector(resetZoom), keyEquivalent: "0").target = self
        addSubmenu(viewMenu, to: mainMenu)

        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addSubmenu(windowMenu, to: mainMenu)

        NSApp.mainMenu = mainMenu
    }

    private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem()
        item.submenu = submenu
        menu.addItem(item)
    }

    @objc private func toggleLogin() {
        if account.isLoggedIn {
            account.logout()
        } else {
            // Signing in happens in the chat window, behind its own button.
            chatWindow.show()
        }
    }

    private func updateLoginItem() {
        loginItem?.title = auth.isLoggedIn ? "ログアウト" : "ログイン…"
    }

    /// Reads the real state each time the menu opens: both can change outside the app.
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateLoginItem()
        for (mode, item) in cleanupItems {
            item.state = mode == Preferences.cleanupMode ? .on : .off
        }
        launchAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func selectCleanupMode(_ sender: NSMenuItem) {
        guard let mode = (sender.representedObject as? String).flatMap(CleanupMode.init) else { return }
        Preferences.cleanupMode = mode
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            show(error)
        }
    }

    @objc private func openAccessibilitySettings() {
        openSettings("Privacy_Accessibility")
    }

    @objc private func openMicrophoneSettings() {
        openSettings("Privacy_Microphone")
    }

    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
