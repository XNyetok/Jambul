import SwiftUI

/// A short message the island shows on its own and then dismisses, like "Charging 80%" or "Timer done".
struct Peek: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var tint: Color
    var title: String
    var detail: String?
    var duration: Duration = .seconds(2.5)
    /// For news the owner must not miss, like a timer ending or a low battery. It waits while nobody can see the island,
    /// comes out even while the island is hidden for a full-screen app, and no other activity's peek cuts it short.
    /// Other peeks are only for whoever happens to be looking.
    var mustBeSeen = false
    /// The activity that sent it. A newer peek from the same one replaces it while it waits, or even while it shows,
    /// since the news has moved on.
    var source = ""
}
