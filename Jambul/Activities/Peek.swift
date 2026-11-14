import SwiftUI

/// A short message the island shows on its own and then dismisses, like "Charging 80%" or "Timer done".
struct Peek: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var tint: Color
    var title: String
    /// Drawn on the right of the title, like "80%" or how long something took.
    var detail: String?
    /// A second line under the title, like the first line of an agent's reply. The peek grows a line taller for it.
    var subtitle: String?
    var duration: Duration = .seconds(2.5)
    /// For news the owner must not miss, like a timer ending or a low battery. It waits while nobody can see the island,
    /// comes out even while the island is hidden for a full-screen app, and no other activity's peek cuts it short.
    /// Other peeks are only for whoever happens to be looking.
    var mustBeSeen = false
    /// The activity that sent it. A newer peek from the same one replaces it while it waits, or even while it shows,
    /// since the news has moved on.
    var source = ""
    /// What the news is about within its activity, like one of several agent sessions. A newer peek replaces only one on
    /// the same topic, and taking peeks back can name one.
    var topic: String?
    /// An image from the app's assets shown in place of `symbol`, such as a subscription's logo.
    var logo: String?
    /// How full something is, from 0 to 1, drawn as a thin bar under the message in `tint`.
    var progress: Double?
    /// The part of `title` drawn in `tint`, like the percentage in "Claude 80%".
    var emphasis: String?
    /// How the symbol or logo moves as the peek comes out.
    var motion: PeekMotion = .none
}

extension Peek {
    /// Whether this is newer news of the same thing as `other`, which it replaces.
    func isSameNews(as other: Peek) -> Bool {
        source == other.source && topic == other.topic
    }
}

/// A peek's symbol moving once as it comes out. Each says something: turning to catch the eye, beating for urgency,
/// dimming as something runs out, jumping as it comes back, popping in and drawing its check as something is done, and
/// shaking its head as something fails. `draw` is for `checkmark.circle.fill`, which it draws itself.
enum PeekMotion: Equatable {
    case none, spin, pulse, sleep, bounce, draw, shake
}
