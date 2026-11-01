import SwiftUI

/// Controls inside the island: a soft pill that brightens and sinks a little while pressed.
///
/// The fill doubles as the hit area, so a click anywhere on a control lands on it instead of toggling the island. The
/// island's window is never key, so system button styles would draw their inactive look; this one sets its own colors.
struct IslandButtonStyle: ButtonStyle {
    nonisolated static let height: CGFloat = 32

    /// Round, for a symbol, rather than a pill sized to its label.
    var isRound = false
    var tint: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, isRound ? 0 : 14)
            .frame(width: isRound ? Self.height : nil, height: Self.height)
            .background(tint.opacity(configuration.isPressed ? 0.32 : 0.18), in: .capsule)
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Motion.buttonPress, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == IslandButtonStyle {
    /// A pill sized to its label, like "25 min", in an activity's color on its own tab.
    static func island(tint: Color = .white) -> Self { IslandButtonStyle(tint: tint) }

    /// A round button holding a symbol.
    static func islandIcon(tint: Color = .white) -> Self { IslandButtonStyle(isRound: true, tint: tint) }
}
