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

/// The platform's standard text sizes, in points at 100%.
enum TextSize {
    case caption
    case callout
    case body
    case title3
    case title2
    case title

    var points: CGFloat {
        #if os(macOS)
        switch self {
        case .caption: return 10
        case .callout: return 12
        case .body: return 13
        case .title3: return 15
        case .title2: return 17
        case .title: return 22
        }
        #else
        switch self {
        case .caption: return 12
        case .callout: return 16
        case .body: return 17
        case .title3: return 20
        case .title2: return 22
        case .title: return 28
        }
        #endif
    }
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
        content.font(.system(size: size.points * zoom, weight: weight, design: design))
    }
}

extension View {
    /// A system font that follows the window's magnification.
    func zoomedFont(_ size: TextSize = .body, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ZoomedFont(size: size, weight: weight, design: design))
    }
}
