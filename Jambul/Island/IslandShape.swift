import SwiftUI

/// The island outline: concave flares at the top that blend into the bezel, rounded corners at the bottom.
/// The flares sit inside `rect`, so the body is `2 * topRadius` narrower than the frame.
struct IslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { (topRadius, bottomRadius) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.width / 4, rect.height / 2)
        let bottom = min(bottomRadius, (rect.width - 2 * top) / 2, rect.height - top)
        let left = rect.minX + top, right = rect.maxX - top

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: left, y: rect.maxY), radius: top)
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.maxY), radius: bottom)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.minY), radius: bottom)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: top)
        path.closeSubpath()
        return path
    }
}
