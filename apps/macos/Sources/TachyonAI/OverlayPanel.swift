import AppKit
import SwiftUI

/// What the floating pill shows.
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var level: Float = 0
    @Published var text = ""
}

/// Always-on-screen pill at the bottom centre. Never takes focus from the app being typed into.
final class OverlayPanel: NSPanel {
    private static let size = NSSize(width: 460, height: 96)

    init(model: OverlayModel) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false

        contentView = NSHostingView(rootView: OverlayView(model: model))
        reposition()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Bottom centre of the screen that currently has the mouse.
    func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(
            x: visible.midX - Self.size.width / 2,
            y: visible.minY + 12))
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    @Namespace private var glass

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            // One piece of glass that changes shape between states, so the pill flows
            // from the idle bar into the recording capsule instead of being swapped.
            GlassEffectContainer {
                content
                    .glassEffect(material, in: .rect(cornerRadius: 20))
                    .glassEffectID("pill", in: glass)
            }
        }
        // Room for the glass shadow, which the panel would otherwise clip.
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.bouncy(duration: 0.35), value: model.phase)
    }

    private var material: Glass {
        switch model.phase {
        case .idle: return .regular
        case .recording: return .regular.tint(.red.opacity(0.35))
        case .transcribing: return .regular.tint(.accentColor.opacity(0.35))
        case .error: return .regular.tint(.yellow.opacity(0.35))
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            Color.clear.frame(width: 44, height: 8)
        case .recording:
            HStack(spacing: 10) {
                Image(systemName: "mic.fill").foregroundStyle(.red)
                LevelBars(level: model.level)
                if !model.text.isEmpty {
                    Text(model.text).lineLimit(2).truncationMode(.head)
                }
            }
            .modifier(PillContent())
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.text.isEmpty ? "文字起こし中…" : model.text)
                    .lineLimit(2).truncationMode(.head)
            }
            .modifier(PillContent())
        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).lineLimit(2)
            }
            .modifier(PillContent())
        }
    }
}

private struct PillContent: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(minHeight: 40)
    }
}

private struct LevelBars: View {
    var level: Float
    private static let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.8, 0.5]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .fill(.primary)
                    .frame(width: 3, height: 4 + 14 * CGFloat(level) * Self.weights[index])
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.08), value: level)
    }
}
