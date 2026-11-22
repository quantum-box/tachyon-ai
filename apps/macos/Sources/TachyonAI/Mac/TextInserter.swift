import AppKit

/// Types text into the frontmost app by pasting it.
enum TextInserter {
    /// Marks the keystrokes this app sends, so its own key monitor can tell them
    /// from the user's.
    static let syntheticEventTag: Int64 = 0x5441_4348

    private static let vKeyCode: CGKeyCode = 9

    /// Pastes `text` once and puts the clipboard back afterwards.
    static func insert(_ text: String) {
        let saved = snapshot()
        paste(text)
        restore(saved, after: 0.5)
    }

    /// Puts `text` on the clipboard and sends ⌘V. The caller restores the clipboard.
    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: keyDown)
            // Exactly ⌘: the fn key the user may still be holding must not be mixed in.
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    struct ClipboardSnapshot {
        fileprivate let items: [NSPasteboardItem]
    }

    static func snapshot() -> ClipboardSnapshot {
        let items = NSPasteboard.general.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        return ClipboardSnapshot(items: items ?? [])
    }

    /// Restores once the target app has read the paste, unless the user copied something meanwhile.
    static func restore(_ snapshot: ClipboardSnapshot, after delay: TimeInterval) {
        let pasteboard = NSPasteboard.general
        let ourChange = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            if !snapshot.items.isEmpty {
                pasteboard.writeObjects(snapshot.items)
            }
        }
    }
}

/// Types a transcript into the frontmost app while it is still being spoken.
///
/// Each call says what the text should be so far; only the new end of it is pasted.
/// Text already in the user's document is never deleted or rewritten: if a later
/// version disagrees with what was typed, the difference is simply not applied.
@MainActor
final class LiveInserter {
    /// Pastes are spaced out so the app has read one before the clipboard holds the next.
    private static let minimumGap: TimeInterval = 0.15

    private var typed = ""
    private var queued = ""
    private var lastPasteAt = Date.distantPast
    private var flushScheduled = false
    private var clipboard: TextInserter.ClipboardSnapshot?
    private var finished = false

    /// Everything handed over so far, pasted or waiting for its turn.
    private var sent: String { typed + queued }

    var hasTypedAnything: Bool { !sent.isEmpty }

    /// Extends the typed text to `target`. Returns false when `target` does not start
    /// with what was already typed (nothing is done in that case).
    @discardableResult
    func extend(to target: String) -> Bool {
        guard target.hasPrefix(sent) else { return false }
        queued += target.dropFirst(sent.count)
        flush()
        return true
    }

    /// Last resort when `target` disagrees with what was typed: the typed part stays as
    /// it is, and whatever `target` has beyond that length is added, so the end of what
    /// was said is not lost.
    func appendRemainder(of target: String) {
        guard target.count > sent.count else { return }
        queued += target.dropFirst(sent.count)
        flush()
    }

    /// No more text is coming: paste what is left, then give the clipboard back.
    func finish() {
        finished = true
        flush()
    }

    private func flush() {
        guard !flushScheduled else { return }
        let wait = Self.minimumGap - Date().timeIntervalSince(lastPasteAt)
        if wait > 0 {
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                self.flushScheduled = false
                self.flush()
            }
            return
        }
        if !queued.isEmpty {
            if clipboard == nil {
                clipboard = TextInserter.snapshot()
            }
            TextInserter.paste(queued)
            typed += queued
            queued = ""
            lastPasteAt = Date()
        }
        if finished, let clipboard {
            self.clipboard = nil
            TextInserter.restore(clipboard, after: 0.5)
        }
    }
}
