import SwiftUI

/// Something Jambul can show in the island: a timer, the battery, what's playing.
///
/// Activities are `@Observable` classes registered with `ActivityCenter`. While `isLive` is true, an activity rests
/// beside the notch in its compact form: alone it takes both sides, and sharing with a more important one it shows its
/// `compactMinimal` glyph on the left. An activity with a `tab` gets its own tab in the open island, which shows one
/// activity at a time: what starts it while idle, its state and controls while live.
@MainActor
protocol IslandActivity: AnyObject, Observable {
    associatedtype CompactLeading: View
    associatedtype CompactTrailing: View
    associatedtype Tab: View = EmptyView

    /// Stable identifier, e.g. "timer".
    var id: String { get }
    /// Its name, as VoiceOver reads its tab.
    var title: String { get }
    var priority: ActivityPriority { get }
    /// Whether the activity has something to show beside the notch right now.
    var isLive: Bool { get }
    /// Width of each slot beside the notch in the compact presentation.
    var compactSlotWidth: CGFloat { get }
    /// Its own color, on its glyphs, its tab and its buttons, so each activity reads as itself at a glance.
    var tint: Color { get }
    /// The symbol on its tab.
    var tabSymbol: String { get }
    /// Whether coming live means the owner started it, which makes its tab the one the island opens on later. One that
    /// comes live on its own, like the usage limits nearing their end, doesn't.
    var countsAsStarted: Bool { get }

    @ViewBuilder var compactLeading: CompactLeading { get }
    @ViewBuilder var compactTrailing: CompactTrailing { get }
    /// A single glyph on the left of the notch, for when a more important activity takes the right.
    var compactMinimal: AnyView { get }
    /// Its tab in the open island, in the room below the notch: mostly one row, as tall as the timer's ring, with its
    /// glyph on the left, what it is in the
    /// middle and its buttons on the right.
    @ViewBuilder var tab: Tab { get }
}

extension IslandActivity {
    var title: String { id }
    var priority: ActivityPriority { .normal }
    var compactSlotWidth: CGFloat { 36 }
    var tint: Color { .white }
    var tabSymbol: String { "circle.fill" }
    var countsAsStarted: Bool { true }
    var compactMinimal: AnyView { AnyView(compactLeading) }

    /// Whether the activity has a tab in the open island.
    var hasTab: Bool { Tab.self != EmptyView.self }

    /// The tab, type-erased for the open island. Erased here rather than at the call site: with the default tab below,
    /// Swift won't open an `any IslandActivity` to read it.
    var anyTab: AnyView { AnyView(tab) }
}

extension IslandActivity where Tab == EmptyView {
    var tab: EmptyView { EmptyView() }
}

enum ActivityPriority: Int, Comparable {
    case low, normal, high

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
