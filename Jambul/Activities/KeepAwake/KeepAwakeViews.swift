import SwiftUI

extension KeepAwakeActivity {
    /// Room beside the notch for how long it has been on: "9h59", the longest (`compactOnFor`), is 34 pt wide there
    /// (measured).
    static let timeSlotWidth: CGFloat = 36

    /// Its eyes, which open as it turns on and close as it turns off.
    var compactLeading: some View {
        KeepAwakeEyes(size: .compact, isOpen: !isClosing, opensAsItAppears: justTurnedOn, closing: closing,
                      tint: tint, lidColor: tint.opacity(0.7))
            .accessibilityHidden(true)
    }

    /// How long it has been on, in its color, so the two sides read as one thing: awake, for so long.
    @ViewBuilder var compactTrailing: some View {
        if let since {
            KeepAwakeMinutes(since: since) { date in
                Text(Self.compactOnFor(date.timeIntervalSince(since)))
            }
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
        }
    }

    /// Its face on the left, which turns it on or off; what it is doing in the middle; its buttons on the right.
    var tab: some View {
        HStack(spacing: 16) {
            KeepAwakeFace(activity: self)
            ZStack(alignment: .leading) {
                if isOn, let since {
                    KeepAwakeMinutes(since: since) { date in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Self.headline(since: since, at: date))
                                .font(IslandLayout.tabHeadlineFont)
                                .monospacedDigit()
                            Text(Self.detailLine(since: since, at: date, untilAgentsFinish: self.untilAgentsFinish))
                                .font(IslandLayout.tabDetailFont)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .transition(Motion.glyphSwap)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep Awake")
                            .font(IslandLayout.tabTitleFont)
                        Text("Display sleeps as usual")
                            .font(IslandLayout.tabDetailFont)
                            .foregroundStyle(.secondary)
                    }
                    .transition(Motion.glyphSwap)
                }
            }
            .lineLimit(1)
            .animation(Motion.tabStateChange, value: isOn)
            Spacer(minLength: 0)
            KeepAwakeControls(activity: self)
        }
        .foregroundStyle(.white)
    }

    /// Its card on Home: its eyes, and how long it has been on in its color, or shut eyes and "Off".
    var homeCard: some View {
        HomeCardContent(Text("Keep Awake")) {
            KeepAwakeEyes(size: .card, isOpen: isOn, closing: closing, tint: tint, lidColor: .white.opacity(0.45))
                .accessibilityHidden(true)
                .islandGlyph(compactGlyph)
        } value: {
            if isOn, let since {
                KeepAwakeMinutes(since: since) { date in
                    Text(Self.onFor(since: since, at: date))
                }
                .foregroundStyle(tint)
            } else {
                Text("Off")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Turned on a moment ago, so the eyes open as they appear, rather than appearing as they are.
    private var justTurnedOn: Bool {
        since.map { Date.now.timeIntervalSince($0) < 1 } ?? false
    }
}

/// Keep Awake's face on its tab: its eyes on a rounded square that glows in its color while on, and shut with a few
/// "z" while off. The whole face is a button that turns it on or off, so the largest thing on the tab is also the
/// easiest to click.
private struct KeepAwakeFace: View {
    let activity: KeepAwakeActivity
    @State private var isHovered = false

    var body: some View {
        Button {
            activity.toggleFromFace()
        } label: {
            ZStack {
                KeepAwakeEyes(size: .face, isOpen: activity.isOn, closing: activity.closing, tint: activity.tint,
                              lidColor: .white.opacity(0.42), peeks: isHovered && !activity.isLive)
                    .islandGlyph(activity.compactGlyph)
                if !activity.isLive {
                    KeepAwakeSnore()
                        .transition(.opacity.combined(with: .offset(y: 4)))
                }
            }
            .frame(width: KeepAwakeFaceStyle.size, height: KeepAwakeFaceStyle.size)
            .animation(Motion.tabStateChange, value: activity.isLive)
        }
        .buttonStyle(KeepAwakeFaceStyle(isOn: activity.isOn, isHovered: isHovered))
        .onHover { isHovered = $0 }
        .accessibilityLabel(activity.isOn ? Text("Turn Off Keep Awake") : Text("Turn On Keep Awake"))
    }
}

/// Three "z" rising from the sleeping face's top right.
private struct KeepAwakeSnore: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(verbatim: "z").font(.system(size: 11, weight: .bold, design: .rounded)).offset(x: 59, y: 15)
            Text(verbatim: "z").font(.system(size: 9, weight: .bold, design: .rounded)).offset(x: 65, y: 8)
            Text(verbatim: "z").font(.system(size: 7, weight: .bold, design: .rounded)).offset(x: 70, y: 2)
        }
        .foregroundStyle(.white.opacity(0.45))
        .frame(width: KeepAwakeFaceStyle.size, height: KeepAwakeFaceStyle.size, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// The face's rounded square: a soft glow in Keep Awake's color while on, a faint fill while off, a little brighter
/// under the pointer, and sinking while pressed, like the island's other buttons. The whole square is its hit area.
private struct KeepAwakeFaceStyle: ButtonStyle {
    static let size: CGFloat = 84
    static let cornerRadius: CGFloat = 26

    let isOn: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let lift = configuration.isPressed ? 0.06 : isHovered ? 0.03 : 0
        configuration.label
            .background {
                ZStack {
                    shape.fill(.white.opacity((isOn ? 0 : 0.07) + lift))
                    shape.fill(RadialGradient(colors: [.cyan.opacity(0.26 + lift), .cyan.opacity(0.1 + lift)],
                                              center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0,
                                              endRadius: Self.size * 0.6))
                        .opacity(isOn ? 1 : 0)
                }
                .animation(Motion.tabStateChange, value: isOn)
            }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.buttonPress, value: configuration.isPressed)
            .animation(Motion.tabHover, value: isHovered)
    }
}

/// Turn Off while it is live, or Turn On, with Until Done below it while a Claude Code session works.
private struct KeepAwakeControls: View {
    let activity: KeepAwakeActivity

    var body: some View {
        // The eyes and the line beside them change at once, so a click on Turn Off shows even while the button stays
        // (`KeepAwakeActivity.offersTurnOff`).
        if activity.offersTurnOff {
            Button { activity.stop() } label: {
                Label("Turn Off", systemImage: "power")
            }
            .buttonStyle(.island())
        } else {
            // Turn On is the one in its color, Until Done under it, so the line beside them keeps its room.
            VStack(alignment: .trailing, spacing: 6) {
                Button { activity.start() } label: {
                    Label("Turn On", systemImage: "power")
                }
                .buttonStyle(.islandProminent(tint: activity.tint))
                // While Claude Code works, Keep Awake can turn itself off as it finishes.
                if activity.agentsAreWorking() {
                    // Asked again on the click: the last turn may have ended since this was drawn, and then there's
                    // nothing to stay on for.
                    Button {
                        if activity.agentsAreWorking() { activity.start(untilAgentsFinish: true) }
                    } label: {
                        Label("Until Done", systemImage: "flag.fill")
                    }
                    .buttonStyle(.island())
                    .accessibilityLabel(Text("Keep Awake Until Claude Code Finishes"))
                }
            }
        }
    }
}

/// Draws `content` for the time now, and again as each minute Keep Awake has been on passes, only while someone can see
/// the island.
struct KeepAwakeMinutes<Content: View>: View {
    let since: Date
    @ViewBuilder let content: (Date) -> Content
    @Environment(\.islandIsVisible) private var isVisible

    var body: some View {
        if isVisible {
            TimelineView(.periodic(from: since, by: 60)) { context in
                content(context.date)
            }
        } else {
            content(.now)
        }
    }
}
