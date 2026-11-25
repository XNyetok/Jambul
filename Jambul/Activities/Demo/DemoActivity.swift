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
        Image("JambulMenuBarIcon")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 14, height: 14)
            .foregroundStyle(.orange)
    }

    var compactTrailing: some View {
        Text("Demo")
            .font(.system(size: 12, weight: .semibold))
    }
}
#endif
