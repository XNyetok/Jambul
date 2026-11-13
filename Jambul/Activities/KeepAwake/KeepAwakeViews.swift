import SwiftUI

extension KeepAwakeActivity {
    /// Room beside the notch for one glyph, the eye or the laptop.
    static let glyphSlotWidth: CGFloat = 22

    /// The eye on the left and on the right a laptop typing code, the kind of work Keep Awake often waits on: the two
    /// sides balance, as Apple asks of them, and move on one beat. Two eyes looked odd with the notch's width between them.
    /// How long it has been on is on its tab.
    var compactLeading: some View {
        BlinkingEye(pointSize: 13, isOpen: !isClosing, opensAsItAppears: justTurnedOn, tint: tint)
            .frame(width: Self.glyphSlotWidth, height: IslandLayout.compactGlyphHeight)
    }

    var compactTrailing: some View {
        TypingLaptop(isOn: !isClosing, typesAsItAppears: justTurnedOn, tint: tint)
            .frame(width: Self.glyphSlotWidth, height: IslandLayout.compactGlyphHeight)
    }

    /// The laptop on its tab: twice the one beside the notch, a whole multiple so its edges stay on the display's
    /// pixels, and as wide as the timer's ring on its own tab.
    static let tabLaptopSize = CGSize(width: LaptopView.size.width * 2, height: LaptopView.size.height * 2)

    /// The laptop from beside the notch, still, with its code showing: in Keep Awake's color while on, dim while off.
    /// The eye stood here first, but with Keep Awake off it was shut, and a shut eye read as a flat line.
    var tab: some View {
        HStack(spacing: 14) {
            StillLaptop(tint: isOn ? tint : .white.opacity(0.36))
                .frame(width: Self.tabLaptopSize.width, height: Self.tabLaptopSize.height)
            VStack(alignment: .leading, spacing: 2) {
                Text("Keep Awake")
                    .font(.headline)
                Group {
                    if isOn, let since {
                        KeepAwakeSince(since: since, untilAgentsFinish: untilAgentsFinish)
                    } else {
                        Text("Display sleeps as usual")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            // Stop stays until Keep Awake leaves the live activities, 0.3 s after it is turned off (`Motion.eyeClose`),
            // and only then does Turn On take its place: that change arms the guard against the rest of a double click
            // on Stop (`IslandModel.acceptsPress`). The laptop and the line beside it change at once, so the click
            // still shows.
            if isLive {
                Button { self.stop() } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.islandIcon())
                .accessibilityLabel(Text("Turn Off Keep Awake"))
            } else {
                // While Claude Code works, Keep Awake can turn itself off as it finishes.
                if agentsAreWorking() {
                    // Asked again on the click: the last turn may have ended since this was drawn, and then there's
                    // nothing to stay on for.
                    Button("Until Done") {
                        if self.agentsAreWorking() { self.start(untilAgentsFinish: true) }
                    }
                        .buttonStyle(.island(tint: tint))
                        .accessibilityLabel(Text("Keep Awake Until Claude Code Finishes"))
                }
                Button("Turn On") { self.start() }
                    .buttonStyle(.island(tint: tint))
            }
        }
        .foregroundStyle(.white)
    }

    /// Its card on Home: how long it has been on, in its color, or "Off".
    var homeCard: some View {
        HomeCardContent(Text("Keep Awake")) {
            Image(systemName: tabSymbol)
                .foregroundStyle(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
        } value: {
            if isOn, let since {
                KeepAwakeSince(since: since, isShort: true)
                    .foregroundStyle(tint)
            } else {
                Text("Off")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Turned on a moment ago, so the eye opens and the laptop types as they appear, rather than appearing as they are.
    private var justTurnedOn: Bool {
        since.map { Date.now.timeIntervalSince($0) < 1 } ?? false
    }
}

/// When Keep Awake was turned on and for how long (`KeepAwakeActivity.sinceLine`), or only for how long
/// (`KeepAwakeActivity.onFor`), redrawn as each minute of it passes, and only while someone can see the island.
struct KeepAwakeSince: View {
    let since: Date
    var untilAgentsFinish = false
    /// Only how long, for its card on Home, which has no room for when.
    var isShort = false
    @Environment(\.islandIsVisible) private var isVisible

    var body: some View {
        if isVisible {
            TimelineView(.periodic(from: since, by: 60)) { context in
                Text(line(at: context.date))
            }
        } else {
            Text(line(at: .now))
        }
    }

    private func line(at date: Date) -> String {
        isShort ? KeepAwakeActivity.onFor(since: since, at: date)
            : KeepAwakeActivity.sinceLine(since: since, at: date, untilAgentsFinish: untilAgentsFinish)
    }
}
