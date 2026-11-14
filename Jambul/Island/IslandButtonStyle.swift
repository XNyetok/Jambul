import SwiftUI

/// Controls inside the island: small, flat capsules and round buttons that brighten under the pointer and sink a little
/// while pressed.
///
/// Only one kind takes color, the action a tab most offers, like Keep Awake's Turn On: a solid fill in its activity's
/// color with dark text, as Apple asks of Liquid Glass (color only the primary action). Every other control is a flat
/// gray capsule or circle. Capsules hold words only, so a label's symbol stays for VoiceOver but isn't drawn.
///
/// The shape doubles as the hit area, so a click anywhere on a control lands on it instead of toggling the island. The
/// island's window is never key, so system button styles would draw their inactive look; this one sets its own colors.
struct IslandButtonStyle: ButtonStyle {
    /// A capsule's height, and a round button's size unless it says otherwise.
    nonisolated static let height: CGFloat = 26
    nonisolated static let roundSize: CGFloat = 32

    /// Round, for a symbol, rather than a capsule sized to its label.
    var isRound = false
    /// Filled with `tint`: the one action a tab most offers.
    var isProminent = false
    var tint: Color = .white
    /// How wide and tall a round button is.
    var size: CGFloat = Self.roundSize

    func makeBody(configuration: Configuration) -> some View {
        IslandButton(configuration: configuration, style: self)
    }
}

extension ButtonStyle where Self == IslandButtonStyle {
    /// A small gray capsule sized to its label, like "Turn Off" or "Until Done".
    static func island() -> Self { IslandButtonStyle() }

    /// The one action a tab most offers, like "Turn On": a solid fill in `tint`, with dark text.
    static func islandProminent(tint: Color) -> Self { IslandButtonStyle(isProminent: true, tint: tint) }

    /// A round button holding a symbol: gray, or a solid fill in `tint` when prominent.
    static func islandIcon(tint: Color = .white, prominent: Bool = false,
                           size: CGFloat = IslandButtonStyle.roundSize) -> Self {
        IslandButtonStyle(isRound: true, isProminent: prominent, tint: tint, size: size)
    }
}

private struct IslandButton: View {
    let configuration: ButtonStyleConfiguration
    let style: IslandButtonStyle
    @State private var isHovered = false

    var body: some View {
        let isPressed = configuration.isPressed
        let size = style.isRound ? style.size : IslandButtonStyle.height
        configuration.label
            .labelStyle(.titleOnly)
            .font(.system(size: style.isRound ? 13 : 12, weight: .semibold))
            .foregroundStyle(style.isProminent ? Color.black.opacity(0.85) : Color.white.opacity(0.9))
            .padding(.horizontal, style.isRound ? 0 : 12)
            .frame(width: style.isRound ? size : nil, height: size)
            .background(fill(isPressed: isPressed), in: .capsule)
            .contentShape(.capsule)
            .scaleEffect(isPressed ? 0.96 : 1)
            .onHover { isHovered = $0 }
            .animation(Motion.buttonPress, value: isPressed)
            .animation(Motion.tabHover, value: isHovered)
    }

    /// Flat: the activity's color for the prominent one, gray for the rest, a step lighter under the pointer, and pressed
    /// a step darker or lighter again.
    private func fill(isPressed: Bool) -> Color {
        if style.isProminent {
            return isPressed ? style.tint.mix(with: .black, by: 0.12)
                : isHovered ? style.tint.mix(with: .white, by: 0.12) : style.tint
        }
        return .white.opacity(isPressed ? 0.22 : isHovered ? 0.16 : 0.1)
    }
}
