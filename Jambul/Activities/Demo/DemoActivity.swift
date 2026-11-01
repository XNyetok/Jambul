#if DEBUG
import SwiftUI

/// A stand-in activity for trying the compact and peek presentations from the Debug menu. It has no tab, so the open
/// island stays as it is for everyday use.
@MainActor
@Observable
final class DemoActivity: IslandActivity {
    let id = "demo"
    var isLive = false
    var compactSlotWidth: CGFloat { 44 }

    var compactLeading: some View {
        Image(systemName: "bird.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.orange)
    }

    var compactTrailing: some View {
        Text("Demo")
            .font(.system(size: 12, weight: .semibold))
    }
}
#endif
