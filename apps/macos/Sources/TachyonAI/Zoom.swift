import SwiftUI

/// The chat window's magnification (⌘+ / ⌘- / ⌘0). Text is laid out at the larger
/// size rather than scaled as an image, so it stays sharp and still wraps to the window.
enum Zoom {
    static let range: ClosedRange<CGFloat> = 0.8...2.0
    static let step: CGFloat = 0.1

    static func clamped(_ value: CGFloat) -> CGFloat {
        // Rounded so repeated steps land back on exactly 1.0.
        let rounded = (value * 10).rounded() / 10
        return min(max(rounded, range.lowerBound), range.upperBound)
    }
}

/// The standard macOS text sizes, in points at 100%.
enum TextSize: CGFloat {
    case caption = 10
    case callout = 12
    case body = 13
    case title3 = 15
    case title2 = 17
    case title = 22
}

private struct ZoomKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var zoom: CGFloat {
        get { self[ZoomKey.self] }
        set { self[ZoomKey.self] = newValue }
    }
}

private struct ZoomedFont: ViewModifier {
    @Environment(\.zoom) private var zoom
    let size: TextSize
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size.rawValue * zoom, weight: weight, design: design))
    }
}

extension View {
    /// A system font that follows the window's magnification.
    func zoomedFont(_ size: TextSize = .body, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ZoomedFont(size: size, weight: weight, design: design))
    }
}
