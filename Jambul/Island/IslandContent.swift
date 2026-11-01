import SwiftUI

/// The live activities beside the notch: leading slot, a gap for the notch itself, trailing slot. Alone, an activity
/// takes both slots; with two, the more important one keeps the right, and the other shows its glyph on the left.
struct CompactContent: View {
    /// The most important first; only the first two show.
    let activities: [any IslandActivity]
    let notch: NotchMetrics
    let slotWidth: CGFloat

    var body: some View {
        // Each slot is known by what fills it, so a slot that keeps its content holds still while the other changes.
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                leading
                    .id(leadingID)
                    .transition(Motion.contentTransition)
            }
            .frame(width: slotWidth, alignment: .leading)
            Color.clear
                .frame(width: notch.size.width)
            ZStack(alignment: .trailing) {
                AnyView(activities[0].compactTrailing)
                    .id(activities[0].id)
                    .transition(Motion.contentTransition)
            }
            .frame(width: slotWidth, alignment: .trailing)
        }
        .padding(.horizontal, IslandLayout.compactInset(notch))
        .frame(height: notch.compactHeight)
        .foregroundStyle(.white)
    }

    private var leading: AnyView {
        activities.count > 1 ? activities[1].compactMinimal : AnyView(activities[0].compactLeading)
    }

    /// The minimal glyph and an activity's own leading view differ even for the same activity.
    private var leadingID: String {
        activities.count > 1 ? "\(activities[1].id).minimal" : activities[0].id
    }
}

struct PeekContent: View {
    let peek: Peek

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: peek.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(peek.tint)
            Text(peek.title)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            if let detail = peek.detail {
                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .foregroundStyle(.white)
    }
}

/// The open island: the tabs beside the notch on the left, the time on the right while a full-screen app hides the
/// menu bar's, and below the notch the chosen activity's tab. One activity at a time, so two never mix on one screen.
struct ExpandedContent: View {
    let model: IslandModel

    var body: some View {
        let notch = model.notch
        let tabs = model.tabs
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                IslandTabBar(tabs: tabs, selected: model.selectedTab) { model.selectTab($0) }
                Spacer(minLength: 0)
                if model.isFullScreen {
                    // Held to the room beside the notch, so the clock picks a face that fits there.
                    IslandClock()
                        .frame(width: IslandLayout.besideNotchRoom(notch), alignment: .trailing)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, IslandLayout.expandedContentInset)
            .frame(height: notch.size.height)

            // Centered in what is left below the notch. Each tab is a row centered on its glyph, so the glyph sits in
            // the same place on every tab, however tall the text beside it.
            ZStack {
                if let tab = tabs.first(where: { $0.id == model.selectedTab }) {
                    tab.anyTab
                        .id(tab.id)
                        .transition(Motion.tabContentTransition(arrivingFrom: model.tabArrivesFrom))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, notch.size.height + IslandLayout.expandedContentTopGap)
            .padding(.bottom, IslandLayout.expandedContentBottomInset)
            .padding(.horizontal, IslandLayout.expandedContentInset)
        }
        .foregroundStyle(.white)
    }
}

/// One button per activity beside the notch. A live activity's symbol shows in its color even while another tab is
/// chosen; the chosen tab sits on a highlight that slides over as the choice changes.
struct IslandTabBar: View {
    let tabs: [any IslandActivity]
    let selected: String?
    let select: (String) -> Void
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: IslandLayout.tabButtonSpacing) {
            ForEach(tabs, id: \.id) { activity in
                let isSelected = activity.id == selected
                Button { select(activity.id) } label: {
                    IslandTabLabel(symbol: activity.tabSymbol, tint: activity.tint, isSelected: isSelected,
                                   isLive: activity.isLive)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(.white.opacity(0.15))
                                    .matchedGeometryEffect(id: "highlight", in: highlight)
                            }
                        }
                }
                .buttonStyle(IslandTabButtonStyle())
                .accessibilityLabel(Text(activity.title))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// A tab's symbol: in the activity's color while chosen or live, otherwise dim, and a little brighter under the pointer.
private struct IslandTabLabel: View {
    let symbol: String
    let tint: Color
    let isSelected: Bool
    let isLive: Bool
    @State private var isHovered = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isSelected || isLive ? tint : .white.opacity(isHovered ? 0.62 : 0.36))
            .frame(width: IslandLayout.tabButtonSize.width, height: IslandLayout.tabButtonSize.height)
            .onHover { isHovered = $0 }
            .animation(Motion.tabHover, value: isHovered)
    }
}

/// A tab's button: the whole pill is its hit area, so a click anywhere on it changes the tab rather than toggling the
/// island, and it sinks a little while pressed, like the island's other buttons.
private struct IslandTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Motion.buttonPress, value: configuration.isPressed)
    }
}

/// The day and time, for while a full-screen app hides the menu bar's clock. Redrawn each minute while it shows, since
/// the island can stay open across one.
struct IslandClock: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            IslandClockFace(date: context.date)
        }
    }
}

/// What `IslandClock` shows at `date`, like "Mon 2  09:41", as the person's locale writes it. The month doesn't fit
/// beside the notch: with it, a day like "Wed 20 May" took 121 pt where there are 106.5 (measured). In the 24-hour
/// locales measured, the day and date fit (99 pt at most), but a 12-hour clock's AM and PM can push them over (112 pt
/// in US English, 120 in Korean), so the date gives way first, then the day, never the time.
struct IslandClockFace: View {
    let date: Date

    /// How much of the day goes before the time, most first. The clock shows the first that fits.
    static var days: [Date.FormatStyle?] {
        [.dateTime.weekday(.abbreviated).day(), .dateTime.weekday(.abbreviated), nil]
    }

    var body: some View {
        let days = Self.days
        ViewThatFits(in: .horizontal) {
            IslandClockLine(date: date, day: days[0])
            IslandClockLine(date: date, day: days[1])
            IslandClockLine(date: date, day: days[2])
        }
    }
}

/// The time at `date`, after the day written in `day`'s format if there is one.
struct IslandClockLine: View {
    let date: Date
    let day: Date.FormatStyle?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let day {
                Text(date, format: day)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(date, format: .dateTime.hour().minute())
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
    }
}
