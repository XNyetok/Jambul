import SwiftUI

extension EnvironmentValues {
    /// Whether anyone can see the island (`IslandModel.isVisible`). Views that redraw by themselves hold still while it
    /// is false: a countdown kept redrawing every second behind the hidden island (measured: 0.4% CPU).
    @Entry var islandIsVisible = true

    /// Shows another tab of the open island from a click on what a tab shows, like a card on Home opening its
    /// activity's tab. The tab replaces what was clicked, so the rest of a double click begun there is ignored.
    @Entry var selectIslandTab = SelectTabAction { _ in }
}

/// Shows the tab of the activity with this id, called like a function: `selectIslandTab("timer")`.
struct SelectTabAction {
    let action: @MainActor (String) -> Void

    @MainActor func callAsFunction(_ id: String) {
        action(id)
    }
}
