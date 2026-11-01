import SwiftUI

extension EnvironmentValues {
    /// Whether anyone can see the island (`IslandModel.isVisible`). Views that redraw by themselves hold still while it
    /// is false: a countdown kept redrawing every second behind the hidden island (measured: 0.4% CPU).
    @Entry var islandIsVisible = true
}
