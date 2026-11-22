import AppKit

/// Reports when the fn (🌐) key is held on its own.
///
/// Uses global event monitors, so the app needs Accessibility permission.
/// fn is treated as a modifier (not dictation) as soon as another key is pressed.
final class FnKeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// fn was combined with another key (fn+arrow etc.): drop the recording.
    var onCancel: (() -> Void)?

    private static let fnKeyCode: UInt16 = 63
    private var monitors: [Any] = []
    private var isDown = false

    func start() {
        let flags: (NSEvent) -> Void = { [weak self] event in self?.flagsChanged(event) }
        let keys: (NSEvent) -> Void = { [weak self] event in
            // The ⌘V this app sends while typing a live transcript is not the user's key.
            let tag = event.cgEvent?.getIntegerValueField(.eventSourceUserData)
            guard tag != TextInserter.syntheticEventTag else { return }
            self?.otherKeyPressed()
        }

        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags),
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys),
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { keys($0); return $0 },
        ].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func flagsChanged(_ event: NSEvent) {
        let fnHeld = event.modifierFlags.contains(.function)
        if fnHeld, !isDown, event.keyCode == Self.fnKeyCode {
            // Ignore fn pressed together with other modifiers (e.g. ctrl+fn shortcuts).
            let others: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            guard event.modifierFlags.intersection(others).isEmpty else { return }
            isDown = true
            onPress?()
        } else if !fnHeld, isDown {
            isDown = false
            onRelease?()
        }
    }

    private func otherKeyPressed() {
        guard isDown else { return }
        isDown = false
        onCancel?()
    }
}
