import os
import SwiftUI

/// Peeks about the battery: plugging in, unplugging, running low, and charging full. It never rests beside the notch.
///
/// Each reading is compared with the one before, since most only change the time remaining. The first reading after
/// launch is only a starting point.
@MainActor
@Observable
final class BatteryActivity: IslandActivity {
    /// Where a low battery is announced, from the first down. macOS warns on its own at 10% and 2%, and a peek there
    /// would only come along with its warning.
    static let lowLevels = [20, 5]
    /// A warning the owner must see, shown as long as the end of a timer.
    static let lowPeekDuration: Duration = .seconds(5)

    let id = "battery"
    var isLive: Bool { false }

    var compactLeading: some View { EmptyView() }
    var compactTrailing: some View { EmptyView() }

    /// Weak, since the center holds its activities.
    @ObservationIgnored private weak var activities: ActivityCenter?
    /// The latest reading, which its card on Home shows; nil before the first, and on a Mac without a battery.
    private(set) var reading: PowerState?
    /// The low levels announced, or already passed, since the charger was last connected.
    @ObservationIgnored private var passedLevels: Set<Int> = []
    /// Whether this charge has reached full and said so.
    @ObservationIgnored private var isFull = false

    init(activities: ActivityCenter) {
        self.activities = activities
    }

    /// Takes a new reading; nil on a Mac without a battery. A reading that misses the battery changes nothing, so the
    /// next real one is still compared with the last.
    func update(_ state: PowerState?) {
        guard let state else { return }
        // Only a change is stored: most readings repeat the last, and its card would redraw for nothing.
        defer { if reading != state { reading = state } }
        guard let last = reading else {
            // Nothing new yet. On battery, the levels already passed don't fire later; on the charger they stay armed,
            // as plugging in would have left them.
            if !state.isOnExternalPower { passLevels(downTo: state.percent) }
            isFull = state.isOnExternalPower && state.percent >= 100
            Logger.activities.notice("""
                battery at \(state.percent, privacy: .public)%, \(state.isOnExternalPower ? "plugged in" : "on battery", privacy: .public)
                """)
            return
        }
        if state.isOnExternalPower != last.isOnExternalPower {
            if state.isOnExternalPower {
                passedLevels = []
                isFull = state.percent >= 100
                announce(isFull ? .full : .charging, at: state.percent)
            } else {
                passLevels(downTo: state.percent)
                announce(.onBattery, at: state.percent)
            }
        } else if state.isOnExternalPower {
            if state.percent >= 100, !isFull {
                isFull = true
                announce(.full, at: state.percent)
            }
        } else if Self.lowLevels.contains(where: { state.percent <= $0 && !passedLevels.contains($0) }) {
            // After a sleep the charge can drop past both levels at once, and one warning says it all.
            passLevels(downTo: state.percent)
            announce(.low, at: state.percent)
        }
    }

    /// Only once there is a reading: a Mac without a battery never gets one.
    var showsHomeCard: Bool { reading != nil }

    /// Its card on Home: the charge, green while plugged in and red once low on battery. It says plugged in rather than
    /// charging, since macOS can hold the charge on the charger, and says it is charging only up to a minute late.
    var homeCard: some View {
        let reading = reading ?? PowerState(percent: 0, isOnExternalPower: false)
        let color: Color? = reading.isOnExternalPower ? .green
            : reading.percent <= (Self.lowLevels.max() ?? 0) ? .red : nil
        HomeCardContent(reading.isOnExternalPower ? Text("Plugged in") : Text("On battery")) {
            Image(systemName: reading.isOnExternalPower ? "battery.100.bolt" : Self.symbol(for: reading.percent))
                .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        } value: {
            Text((Double(reading.percent) / 100).formatted(.percent))
                .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                .contentTransition(Motion.numberTransition(value: Double(reading.percent)))
                .animation(Motion.valueChange, value: reading.percent)
        }
    }

    /// The battery symbol nearest `percent`, like the menu bar's.
    static func symbol(for percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0"
        case ..<38: "battery.25"
        case ..<63: "battery.50"
        case ..<88: "battery.75"
        default: "battery.100"
        }
    }

    #if DEBUG
    /// Names for `showSample(_:)`, in order.
    static let sampleNames = ["Charging", "On Battery", "Low Battery", "Fully Charged"]

    /// Shows one kind of peek, for trying it on the notch without waiting for the battery. Readings stay as they are.
    func showSample(_ index: Int) {
        let samples: [(News, Int)] = [(.charging, 62), (.onBattery, 62), (.low, 20), (.full, 100)]
        let (news, percent) = samples[index % samples.count]
        announce(news, at: percent)
    }
    #endif

    private enum News {
        case charging, full, onBattery, low
    }

    private func passLevels(downTo percent: Int) {
        passedLevels.formUnion(Self.lowLevels.filter { percent <= $0 })
    }

    private func announce(_ news: News, at percent: Int) {
        let detail = (Double(percent) / 100).formatted(.percent)
        let peek = switch news {
        case .charging:
            Peek(symbol: "bolt.fill", tint: .green, title: String(localized: "Charging"), detail: detail, source: id)
        case .full:
            Peek(symbol: "battery.100.bolt", tint: .green, title: String(localized: "Fully charged"), detail: detail,
                 source: id)
        case .onBattery:
            Peek(symbol: Self.symbol(for: percent), tint: .white, title: String(localized: "On battery"),
                 detail: detail, source: id)
        case .low:
            Peek(symbol: Self.symbol(for: percent), tint: .red, title: String(localized: "Low battery"), detail: detail,
                 duration: Self.lowPeekDuration, mustBeSeen: true, source: id)
        }
        Logger.activities.notice("battery: \(peek.title, privacy: .public), \(percent, privacy: .public)%")
        activities?.peek(peek)
    }
}
