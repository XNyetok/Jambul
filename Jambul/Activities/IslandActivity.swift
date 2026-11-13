import SwiftUI

/// Something Jambul can show in the island: a timer, the battery, what's playing.
///
/// Activities are `@Observable` classes registered with `ActivityCenter`. While `isLive` is true, an activity rests
/// beside the notch in its compact form: alone it takes both sides, and sharing with a more important one it shows its
/// `compactMinimal` glyph on the left. An activity with a `tab` gets its own tab in the open island, which shows one
/// activity at a time: what starts it while idle, its state and controls while live. One with a `homeCard` also shows
/// on Home, the first tab, which sums up what each is doing.
@MainActor
protocol IslandActivity: AnyObject, Observable {
    associatedtype CompactLeading: View
    associatedtype CompactTrailing: View
    associatedtype Tab: View = EmptyView
    associatedtype HomeCard: View = EmptyView

    /// Stable identifier, e.g. "timer".
    var id: String { get }
    /// Its name, as VoiceOver reads its tab.
    var title: String { get }
    var priority: ActivityPriority { get }
    /// Whether the activity has something to show beside the notch right now.
    var isLive: Bool { get }
    /// Width of its slot right of the notch in the compact presentation.
    var compactSlotWidth: CGFloat { get }
    /// Width of its slot left of the notch, for `compactLeading` and `compactMinimal`: as wide as the right one unless
    /// it says otherwise. Each side is only as wide as what it holds, so its content sits close to the notch.
    var compactLeadingWidth: CGFloat { get }
    /// What the glyph left of the notch is, if the open island shows it too, on the activity's tab or its card on Home
    /// (`islandGlyph`). As the island opens the glyph travels there rather than fading out beside the notch.
    var compactGlyph: String? { get }
    /// Its own color, on its glyphs, its tab and its buttons, so each activity reads as itself at a glance.
    var tint: Color { get }
    /// The symbol on its tab.
    var tabSymbol: String { get }
    /// The color of that symbol while the activity has something going on, or nil while it has not: the symbol is then
    /// white on the chosen tab and dim on the others.
    var tabTint: Color? { get }
    /// Whether its card on Home has nothing going on, like a timer that is off. Such a card dims, so the others stand out.
    var homeCardIsQuiet: Bool { get }
    /// Whether its card shows on Home now. One with nothing to say for a while stays off it, like the usage limits with
    /// every subscription turned off.
    var showsHomeCard: Bool { get }

    @ViewBuilder var compactLeading: CompactLeading { get }
    @ViewBuilder var compactTrailing: CompactTrailing { get }
    /// A single glyph on the left of the notch, for when a more important activity takes the right.
    var compactMinimal: AnyView { get }
    /// Its tab in the open island, in the room below the notch: mostly one row, as tall as the timer's ring, with its
    /// glyph on the left, what it is in the
    /// middle and its buttons on the right.
    @ViewBuilder var tab: Tab { get }
    /// Its card on Home: what it is doing now, at a glance, laid out with `HomeCardContent`.
    @ViewBuilder var homeCard: HomeCard { get }
}

extension IslandActivity {
    var title: String { id }
    var priority: ActivityPriority { .normal }
    var compactSlotWidth: CGFloat { 36 }
    var compactLeadingWidth: CGFloat { compactSlotWidth }
    var compactGlyph: String? { nil }
    var tint: Color { .white }
    var tabSymbol: String { "circle.fill" }
    var tabTint: Color? { isLive ? tint : nil }
    var homeCardIsQuiet: Bool { false }
    var showsHomeCard: Bool { hasHomeCard }
    var compactMinimal: AnyView { AnyView(compactLeading) }

    /// Whether the activity has a tab in the open island.
    var hasTab: Bool { Tab.self != EmptyView.self }

    /// Whether the activity has a card on Home.
    var hasHomeCard: Bool { HomeCard.self != EmptyView.self }

    /// The tab, type-erased for the open island. Erased here rather than at the call site: with the default tab below,
    /// Swift won't open an `any IslandActivity` to read it.
    var anyTab: AnyView { AnyView(tab) }

    /// The card, type-erased for Home, for the same reason as `anyTab`.
    var anyHomeCard: AnyView { AnyView(homeCard) }
}

extension IslandActivity where Tab == EmptyView {
    var tab: EmptyView { EmptyView() }
}

extension IslandActivity where HomeCard == EmptyView {
    var homeCard: EmptyView { EmptyView() }
}

enum ActivityPriority: Int, Comparable {
    case low, normal, high

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
