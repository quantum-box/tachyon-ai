import AppKit
import ApplicationServices

/// Watches the text field a dictation was pasted into, to learn from what the user
/// changes in it: a word they rewrite is one the transcription got wrong.
///
/// The field is read through Accessibility, which the app already has for the fn key.
/// Its contents stay in memory and are only compared with the pasted text; nothing but
/// the rewritten word is kept. Apps that do not expose their text this way (and
/// password fields) are simply not watched.
@MainActor
final class CorrectionWatcher {
    private struct Watch {
        let element: AXUIElement
        let pasted: String
        /// The field's text before and after the pasted part, which must stay as they are.
        let prefix: String
        let suffix: String
        /// The pasted part as it reads now.
        var current: String
        let startedAt = Date()
        var changedAt = Date()
    }

    private var watch: Watch?
    private var timer: Timer?
    private var pending: DispatchWorkItem?

    /// The paste needs a moment to land in the other app.
    private static let settleDelay: TimeInterval = 0.6
    private static let pollInterval: TimeInterval = 1
    /// How long after the last change the user is taken to be done fixing.
    private static let quietPeriod: TimeInterval = 8
    private static let maximumDuration: TimeInterval = 90
    private static let maximumFieldLength = 20_000

    /// Starts watching for fixes to `pasted`, which was just typed into the frontmost app.
    func begin(pasted: String) {
        finish()
        guard Preferences.autoLearnTerms, pasted.count >= 2, AXIsProcessTrusted() else { return }
        let start = DispatchWorkItem { [weak self] in self?.start(pasted: pasted) }
        pending = start
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: start)
    }

    /// Stops watching and learns from what changed so far.
    func finish() {
        pending?.cancel()
        pending = nil
        timer?.invalidate()
        timer = nil
        guard let watch else { return }
        self.watch = nil
        Vocabulary.shared.learn(TermLearning.corrections(from: watch.pasted, to: watch.current))
    }

    private func start(pasted: String) {
        pending = nil
        guard let element = Self.focusedElement(), let value = Self.text(of: element),
              // The pasted text is the one that ends at the cursor; failing that, the last one.
              let range = Self.range(of: pasted, endingAtCursorOf: element, in: value)
                ?? value.range(of: pasted, options: .backwards) else { return }
        watch = Watch(
            element: element, pasted: pasted,
            prefix: String(value[..<range.lowerBound]), suffix: String(value[range.upperBound...]),
            current: pasted)
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard var watch else { return }
        let now = Date()
        // Moving to another field, sending the message (the field empties) or editing
        // outside the pasted part ends the watch; what was last seen is what counts.
        guard let focused = Self.focusedElement(), CFEqual(focused, watch.element),
              let value = Self.text(of: watch.element),
              value.count >= watch.prefix.count + watch.suffix.count,
              value.hasPrefix(watch.prefix), value.hasSuffix(watch.suffix) else {
            finish()
            return
        }
        let current = String(value.dropFirst(watch.prefix.count).dropLast(watch.suffix.count))
        // An emptied field is a sent message when nothing else was in it: the same end
        // of the watch, and not a deletion to take as the latest state.
        guard !current.isEmpty else {
            finish()
            return
        }
        if current != watch.current {
            watch.current = current
            watch.changedAt = now
            self.watch = watch
        }
        let fixed = watch.current != watch.pasted && now.timeIntervalSince(watch.changedAt) >= Self.quietPeriod
        if fixed || now.timeIntervalSince(watch.startedAt) >= Self.maximumDuration {
            finish()
        }
    }

    // MARK: - Accessibility

    private static func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    private static func text(of element: AXUIElement) -> String? {
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != (kAXSecureTextFieldSubrole as String) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String, text.utf16.count <= maximumFieldLength else { return nil }
        return text
    }

    private static func range(
        of pasted: String, endingAtCursorOf element: AXUIElement, in value: String
    ) -> Range<String.Index>? {
        var selection: CFTypeRef?
        var selected = CFRange()
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
            let selection, CFGetTypeID(selection) == AXValueGetTypeID(),
            AXValueGetValue(selection as! AXValue, .cfRange, &selected),
            selected.location >= 0, selected.location <= value.utf16.count,
            let end = String.Index(utf16Offset: selected.location, in: value).samePosition(in: value),
            value[..<end].hasSuffix(pasted) else { return nil }
        return value.index(end, offsetBy: -pasted.count)..<end
    }
}
