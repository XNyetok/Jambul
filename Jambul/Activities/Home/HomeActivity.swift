import SwiftUI

/// The open island's first tab, the one it opens on as Jambul starts: a card for each activity that has one, saying what
/// it is doing now. A click on a card opens that activity's tab. Home never comes beside the notch.
@MainActor
@Observable
final class HomeActivity: IslandActivity {
    let id = "home"
    var title: String { String(localized: "Home") }
    var isLive: Bool { false }
    var tabSymbol: String { "house.fill" }

    /// Weak, since the center holds its activities.
    @ObservationIgnored private weak var activities: ActivityCenter?

    init(activities: ActivityCenter) {
        self.activities = activities
    }

    var compactLeading: some View { EmptyView() }
    var compactTrailing: some View { EmptyView() }
    var tab: some View { HomeTab(center: activities) }
}

/// One card for each activity that has one, side by side and all one size, in the order Jambul registers them. A click
/// on a card opens that activity's tab, as a click on the tab's own button does; the battery has no tab to open.
struct HomeTab: View {
    let center: ActivityCenter?
    @Environment(\.selectIslandTab) private var selectTab

    var body: some View {
        let activities = (center?.activities ?? []).filter(\.showsHomeCard)
        HStack(spacing: HomeCardStyle.spacing) {
            ForEach(activities, id: \.id) { activity in
                if activity.hasTab {
                    Button { selectTab(activity.id) } label: {
                        activity.anyHomeCard
                    }
                    .buttonStyle(HomeCardButtonStyle(isQuiet: activity.homeCardIsQuiet))
                } else {
                    activity.anyHomeCard
                        .homeCardFrame(fill: HomeCardStyle.fill)
                }
            }
        }
        .frame(maxHeight: HomeCardStyle.height)
    }
}

/// What a card on Home holds: the activity's symbol at the top, and at the bottom what it is doing, large, over what it
/// is. The symbol and the value take the activity's color while it is on, and stay dim while it is off.
struct HomeCardContent<Glyph: View, Value: View>: View {
    let label: Text
    let glyph: Glyph
    let value: Value

    init(_ label: Text, @ViewBuilder glyph: () -> Glyph, @ViewBuilder value: () -> Value) {
        self.label = label
        self.glyph = glyph()
        self.value = value()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            glyph
                .font(.system(size: 15, weight: .semibold))
                .frame(height: HomeCardStyle.glyphHeight, alignment: .leading)
            Spacer(minLength: 0)
            value
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
            label
                .font(HomeCardStyle.labelFont)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// The measures every card on Home shares.
enum HomeCardStyle {
    /// Below the MacBook Air's notch the room for a tab is 100 pt tall, so a card leaves even margins above and below.
    static let height: CGFloat = 78
    static let spacing: CGFloat = 8
    static let cornerRadius: CGFloat = 16
    static let padding = EdgeInsets(top: 10, leading: 11, bottom: 10, trailing: 11)
    static let glyphHeight: CGFloat = 18
    static let labelFont = Font.system(size: 11, weight: .medium)
    /// The card's fill at rest, under the pointer, and pressed, a step brighter each time.
    static let fill = 0.08
    /// A card with nothing going on: a fainter fill, and its content dimmed.
    static let quietFill = 0.045
    static let quietOpacity = 0.7
    static let hoveredFill = 0.11
    static let pressedFill = 0.16
}

extension View {
    /// A card's frame on Home: padded, as wide as every other card, on a soft fill.
    func homeCardFrame(fill: Double) -> some View {
        padding(HomeCardStyle.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white.opacity(fill), in: .rect(cornerRadius: HomeCardStyle.cornerRadius, style: .continuous))
    }
}

/// A card on Home as a button. The whole card is its hit area, so a click anywhere on it opens the tab rather than
/// toggling the island; like the island's other controls, it brightens under the pointer and sinks while pressed.
private struct HomeCardButtonStyle: ButtonStyle {
    var isQuiet = false

    func makeBody(configuration: Configuration) -> some View {
        HomeCardButton(configuration: configuration, isQuiet: isQuiet)
    }
}

private struct HomeCardButton: View {
    let configuration: ButtonStyleConfiguration
    let isQuiet: Bool
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .opacity(isQuiet && !isHovered ? HomeCardStyle.quietOpacity : 1)
            .homeCardFrame(fill: configuration.isPressed ? HomeCardStyle.pressedFill
                           : isHovered ? HomeCardStyle.hoveredFill
                           : isQuiet ? HomeCardStyle.quietFill : HomeCardStyle.fill)
            .contentShape(.rect(cornerRadius: HomeCardStyle.cornerRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .onHover { isHovered = $0 }
            .animation(Motion.buttonPress, value: configuration.isPressed)
            .animation(Motion.tabHover, value: isHovered)
    }
}
