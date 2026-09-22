import SwiftUI

/// The shared separator used throughout Tomo.
///
/// Keep its color and thickness here so horizontal and vertical dividers stay
/// visually consistent across every surface.
struct CodexDivider: View {
    /// Design maximum. Retina displays use a one-physical-pixel hairline
    /// instead, avoiding a fractional line being antialiased across two pixels.
    static let thickness: CGFloat = 0.7
    static let color = Color.codexLine.opacity(0.72)

    let axis: Axis
    @Environment(\.displayScale) private var displayScale

    init(_ axis: Axis = .horizontal) {
        self.axis = axis
    }

    static func renderedThickness(displayScale: CGFloat) -> CGFloat {
        min(thickness, 1 / max(displayScale, 1))
    }

    var body: some View {
        let renderedThickness = Self.renderedThickness(displayScale: displayScale)

        Rectangle()
            .fill(Self.color)
            .frame(
                maxWidth: axis == .horizontal ? .infinity : nil,
                maxHeight: axis == .vertical ? .infinity : nil
            )
            .frame(
                width: axis == .vertical ? renderedThickness : nil,
                height: axis == .horizontal ? renderedThickness : nil
            )
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
