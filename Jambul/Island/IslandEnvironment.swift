import SwiftUI

extension EnvironmentValues {
    /// Whether anyone can see the island (`IslandModel.isVisible`). Views that redraw by themselves hold still while it
    /// is false: a countdown kept redrawing every second behind the hidden island (measured: 0.4% CPU).
    @Entry var islandIsVisible = true

    /// Shows another tab of the open island from a click on what a tab shows, like a card on Home opening its
    /// activity's tab. The tab replaces what was clicked, so the rest of a double click begun there is ignored.
    @Entry var selectIslandTab = SelectTabAction { _ in }

    /// Where the island's glyphs are matched up, so the one left of the notch can travel to its place in the open
    /// island (`islandGlyph`). Nil outside the island, as in Settings and where a view is drawn alone.
    @Entry var islandGlyphs: Namespace.ID?

    /// The glyph on its way from beside the notch to its place in the open island, which stays hidden there until it
    /// lands.
    @Entry var islandGlyphInFlight: String?
}

/// The glyphs the open island shows now that the one left of the notch could travel to, each with the name its place
/// is matched under. Every place has a name of its own, so a glyph on Home and the same one on its tab are never
/// matched to each other: changing tabs must not send it flying from one to the other.
struct IslandGlyphsShown: PreferenceKey {
    static let defaultValue: [String: String] = [:]

    static func reduce(value: inout [String: String], nextValue: () -> [String: String]) {
        value.merge(nextValue()) { first, _ in first }
    }
}

enum IslandGlyphs {
    /// What the travelling glyph is matched to while it rests beside the notch: nothing marks this, so it stays where
    /// it is laid out.
    static let resting = "compact.leading"
}

extension View {
    /// Marks a glyph in the open island as the same thing as the one left of the notch with this id
    /// (`IslandActivity.compactGlyph`): as the island opens, that one travels here, and back as it closes.
    func islandGlyph(_ id: String?) -> some View {
        modifier(IslandGlyphPlace(id: id))
    }
}

private struct IslandGlyphPlace: ViewModifier {
    let id: String?
    @Environment(\.islandGlyphs) private var glyphs
    @Environment(\.islandGlyphInFlight) private var inFlight
    /// This place's own name.
    @State private var place = UUID().uuidString

    func body(content: Content) -> some View {
        if let glyphs, let id {
            content
                .opacity(inFlight == id ? 0 : 1)
                .matchedGeometryEffect(id: place, in: glyphs)
                .preference(key: IslandGlyphsShown.self, value: [id: place])
        } else {
            content
        }
    }
}

/// The glyph left of the notch, drawn over the island's content so it can leave its slot. At rest it sits where its
/// parent lays it out, at the slot's left edge, like any content. With a `place` in the open island it takes that
/// place's position and height instead, and moves there and back on the island's spring.
struct IslandGlyphFlyer: View {
    let glyph: AnyView
    let place: String?
    let glyphs: Namespace.ID

    var body: some View {
        GeometryReader { proxy in
            glyph
                .scaleEffect(proxy.size.height / IslandLayout.compactGlyphHeight)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: place == nil ? .leading : .center)
        }
        .matchedGeometryEffect(id: place ?? IslandGlyphs.resting, in: glyphs, isSource: false)
        .allowsHitTesting(false)
    }
}

/// Shows the tab of the activity with this id, called like a function: `selectIslandTab("timer")`.
struct SelectTabAction {
    let action: @MainActor (String) -> Void

    @MainActor func callAsFunction(_ id: String) {
        action(id)
    }
}
