import SwiftUI

/// The shell outline. Square at the screen edge, rounded at the bottom, with a
/// concave shoulder on each side so the glass looks poured out of the notch
/// instead of stuck on top of it.
struct NotchShape: Shape {
    /// Radius of the concave curve where the shell meets the screen edge.
    var shoulder: CGFloat = 10
    /// Radius of the two bottom corners.
    var bottom: CGFloat = 18

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottom) }
        set {
            shoulder = newValue.first
            bottom = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Keep the radii inside the rect on the small idle size.
        let shoulderRadius = min(shoulder, rect.width / 2, rect.height)
        let bottomRadius = min(bottom, rect.width / 2, max(rect.height - shoulderRadius, 0))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX - shoulderRadius, y: rect.minY))
        // Concave shoulder on the left.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + shoulderRadius),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + shoulderRadius))
        // Concave shoulder on the right.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + shoulderRadius, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
