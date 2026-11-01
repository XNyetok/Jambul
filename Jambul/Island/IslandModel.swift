import Observation
import os
import SwiftUI

enum IslandPresentation: Equatable {
    /// Hidden behind the physical notch.
    case idle
    /// A live activity rests beside the notch.
    case compact
    /// The pointer is resting on the island: a small lift hints that it can open.
    case lifted
    /// A short message, shown on its own and dismissed after a moment.
    case peek
    /// Fully open.
    case expanded
}

/// Parts of the screen that count as "on the island".
enum PointerRegion: Hashable {
    case notch, island
}

/// The island's state machine. Views are a pure function of it; the window controller only
/// follows along through `onPresentationChange`.
///
/// Hovering opens the island after a short intent delay and leaving closes it. A click toggles it: opening skips
/// the intent delay, and closing folds it back to the lifted pill while the pointer stays, so it never vanishes
/// from under the pointer.
///
/// Peeks show while the island rests. One that arrives while the owner has the island open, or is about to open it,
/// waits, and shows as the island closes if it is still fresh by then. One the owner must see also waits while nobody
/// can see the island, until someone can, and never gives way to another activity's peek: those wait their turn.
///
/// The open island shows one activity's tab at a time. It opens on the most important live activity's tab, or with
/// nothing live on the tab of the activity started last, remembered across launches. Only a click on another tab
/// changes it while it is open, and only for then: looking at a tab doesn't make the island open there next time.
@MainActor
@Observable
final class IslandModel {
    private(set) var presentation: IslandPresentation
    /// The live activities the island shows, the most important first. They change together with `presentation`, so
    /// both animate as one.
    private(set) var liveActivities: [any IslandActivity]
    private(set) var peek: Peek?
    /// The activity whose tab the open island shows.
    private(set) var selectedTab: String?
    /// The side the shown tab's content came in from: the side its tab lies on, seen from the tab before it.
    private(set) var tabArrivesFrom = HorizontalEdge.trailing
    /// Whether a full-screen app has the screen, hiding the menu bar and its clock. The open island shows the time then.
    var isFullScreen = false
    /// Room kept beside the notch for the pointer. An activity that ends while the pointer rests on the lifted island or
    /// a peek would otherwise narrow the island out from under it; the room goes once the island settles or opens.
    private(set) var heldSlotWidth: CGFloat?
    /// Whether anyone can see the island: not while the display sleeps or the screen is locked, nor while it rests hidden
    /// for a full-screen app. Views that redraw by themselves, like a countdown, hold still meanwhile.
    private(set) var isVisible = true
    var notch: NotchMetrics

    /// Called right before the presentation changes, so the window can prepare for it.
    @ObservationIgnored var onPresentationChange: (@MainActor (_ from: IslandPresentation, _ to: IslandPresentation) -> Void)?
    /// How long the pointer has to rest on the notch before the island opens.
    @ObservationIgnored var hoverIntent = HoverSpeed.normal.intent
    /// Whether anyone can see the island right now: not while the display sleeps or the screen is locked. Asked as
    /// each peek arrives, since the notifications that say so can come after it.
    @ObservationIgnored var canBeSeen: @MainActor () -> Bool = { true }
    /// Whether the pointer is over the island as it is drawn now. Asked as a peek appears: a peek can grow under a
    /// pointer, which only reports arriving once it moves.
    @ObservationIgnored var isPointerOnIsland: @MainActor () -> Bool = { false }
    /// Asked to watch the pointer, and to stop, while hover waits for it to leave a peek that appeared under it. A pointer
    /// never reported on the island can move off it without being reported leaving; the watch says so instead
    /// (`pointerIsOffIsland`).
    @ObservationIgnored var watchesPointer: (@MainActor (_ watching: Bool) -> Void)?
    /// True while the owner has the island hidden for a full-screen app. Only a peek they must see comes out then,
    /// and the window controller shows the island until it is back at rest.
    @ObservationIgnored var isHidden = false {
        didSet { updateVisibility() }
    }

    private let center: ActivityCenter
    @ObservationIgnored private var pointerRegions: Set<PointerRegion> = []
    @ObservationIgnored private var expandTask: Task<Void, Never>?
    /// Closing once the pointer has left.
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    /// The showing peek's own time running out.
    @ObservationIgnored private var peekTask: Task<Void, Never>?
    /// Set while the pointer is on the island without having come to open it: a click closed the island under it, or a
    /// peek appeared under it. Hover leaves the island alone until the pointer has really left.
    @ObservationIgnored private var hoverHeldOff = false {
        didSet { updatePointerWatch() }
    }
    /// Set for a peek that appeared under the pointer. The pointer didn't come for it, so leaving doesn't cut it short.
    @ObservationIgnored private var peekKeepsItsTime = false {
        didSet { updatePointerWatch() }
    }
    @ObservationIgnored private var isWatchingPointer = false
    /// Set when the display sleeps or the screen locks, until someone can see the island again. Taken at its word, since
    /// what `canBeSeen` reads can lag behind the notification.
    @ObservationIgnored private var isOutOfSight = false
    /// Set when the open island's content changes, until the next fresh click. The rest of a double click begun before
    /// was aimed at what was there before, like the second click on "25 min" landing on the timer that replaced it.
    @ObservationIgnored private var pressesAimAtOldContent = false
    /// Peeks waiting for their turn: the ones the owner must see first, the rest in the order they came.
    @ObservationIgnored private var waiting: [WaitingPeek] = []
    /// When the peek showing now is due to close, for lining up the next one behind it.
    @ObservationIgnored private var peekEnds: ContinuousClock.Instant?
    /// The tab of the activity started last, for opening with nothing live. Starting it from anywhere counts, the menu
    /// bar too; a glance at a tab doesn't, or the next opening would land on a tab the owner only looked at.
    @ObservationIgnored private var lastStartedTab: String? {
        didSet {
            guard lastStartedTab != oldValue else { return }
            Logger.island.notice("opening tab → \(self.lastStartedTab ?? "none", privacy: .public)")
            defaults?.set(lastStartedTab, forKey: Self.lastStartedTabKey)
        }
    }
    private let defaults: UserDefaults?
    private static let lastStartedTabKey = "lastStartedTab"

    /// - Parameter defaults: Where the tab started last is kept for the next launch. Without one, as in tests and
    ///   previews, it lasts only as long as the model.
    init(notch: NotchMetrics, activities: ActivityCenter, presentation: IslandPresentation? = nil, peek: Peek? = nil,
         defaults: UserDefaults? = nil) {
        let live = activities.liveActivities
        self.notch = notch
        self.center = activities
        self.defaults = defaults
        lastStartedTab = defaults?.string(forKey: Self.lastStartedTabKey)
        self.liveActivities = live
        self.peek = peek
        self.presentation = presentation ?? (live.isEmpty ? .idle : .compact)
        if self.presentation == .expanded { selectedTab = tabOnOpening }
        activities.onLiveActivityChange = { [weak self] in self?.liveActivityDidChange() }
        activities.onPeek = { [weak self] in self?.show($0) }
    }

    /// The most important live activity.
    var activity: (any IslandActivity)? { liveActivities.first }

    /// The activities beside the notch: the two most important live ones.
    var compactActivities: [any IslandActivity] { Array(liveActivities.prefix(2)) }

    /// The activities with a tab in the open island, in the order they were registered.
    var tabs: [any IslandActivity] { center.activities.filter(\.hasTab) }

    /// Each slot's width beside the notch: the widest the compact activities need, or the room held for the pointer if
    /// that is wider. Both sides match, so the island stays centered on the notch.
    var compactSlotWidth: CGFloat? {
        let own = compactActivities.map(\.compactSlotWidth).max()
        guard let heldSlotWidth else { return own }
        return max(heldSlotWidth, own ?? 0)
    }

    /// The island's size and corners as it is drawn now, for the view and for finding the pointer on it alike.
    var layout: IslandLayout {
        IslandLayout(presentation, notch: notch, compactSlotWidth: compactSlotWidth)
    }

    /// Shows another activity's tab in the open island, from a click on it. The island opens there again only once
    /// something on it starts.
    func selectTab(_ id: String) {
        let tabs = self.tabs
        guard let next = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard presentation == .expanded, id != selectedTab else { return }
        let current = tabs.firstIndex { $0.id == selectedTab } ?? next
        Logger.island.notice("tab → \(id, privacy: .public)")
        withAnimation(Motion.tabChange) {
            tabArrivesFrom = next > current ? .trailing : .leading
            selectedTab = id
        }
    }

    func pointer(_ region: PointerRegion, isInside: Bool) {
        if isInside {
            pointerRegions.insert(region)
        } else {
            pointerRegions.remove(region)
        }
        if pointerRegions.isEmpty { pointerLeft() } else { pointerArrived() }
    }

    /// The pointer watch saw the pointer away from the island. A pointer under a peek it never came for has now left it,
    /// so coming back to the peek is coming for it.
    func pointerIsOffIsland() {
        // A pointer the island knows about reports leaving on its own.
        guard hoverHeldOff, peekKeepsItsTime, pointerRegions.isEmpty else { return }
        Logger.island.notice("pointer moved off a peek it never came for")
        hoverHeldOff = false
    }

    /// Asked before each press on the island or the notch reaches it. A fresh click always counts; the rest of a double
    /// click begun before the open island's content changed doesn't, since it was aimed at what was there before.
    func acceptsPress(clickCount: Int) -> Bool {
        guard clickCount > 1 else {
            pressesAimAtOldContent = false
            return true
        }
        if pressesAimAtOldContent {
            Logger.island.notice("press ignored: the rest of a double click on content that has changed")
        }
        return !pressesAimAtOldContent
    }

    /// Toggles the island. Closing folds it back to the lifted pill while the pointer is still on it, and hover
    /// leaves it closed until the pointer goes away; another click opens it again.
    func clicked() {
        Logger.island.notice("click while \(String(describing: self.presentation), privacy: .public)")
        cancelPendingTransitions()
        if presentation == .expanded {
            if pointerRegions.isEmpty {
                settle()
            } else {
                hoverHeldOff = true
                present(.lifted)
            }
        } else {
            hoverHeldOff = false
            present(.expanded)
        }
    }

    /// Forgets the pointer and settles the island at rest, for when its windows go away. A peek the owner must see,
    /// showing or waiting, still comes out, as it does while the island is hidden.
    func reset() {
        pointerRegions.removeAll()
        cancelPendingTransitions()
        keepWaitingOnlyForWhatMustBeSeen()
        present(resting)
        if canBeSeen(), let next = nextWaitingPeek() { presentPeek(next) }
    }

    func show(_ peek: Peek) {
        // Newer news from the same activity replaces any of its own still waiting.
        waiting.removeAll { $0.peek.source == peek.source }
        // With nobody to see it, a peek the owner must see waits for them, and any other would be missed anyway.
        guard canBeSeen() else {
            if peek.mustBeSeen { line(up: peek, until: nil) }
            return
        }
        guard !isHidden || peek.mustBeSeen else { return }
        if presentation == .peek, let showing = self.peek, showing.mustBeSeen, showing.source != peek.source {
            // Never cut short a peek the owner must see: this one follows it.
            line(up: peek, until: peek.mustBeSeen ? nil : max(peekEnds ?? .now, .now) + peek.duration)
            return
        }
        // Don't interrupt someone who is looking at the island, or whose hover is about to open it: the peek waits
        // until it closes. Replacing the peek under the pointer would only flash it before the island opens. A lifted
        // island that isn't about to open, as after a click closed it, takes the peek at once, since it only grows from
        // there; unless others are waiting, which go first.
        let liftedAndFree = presentation == .lifted && expandTask == nil && waiting.isEmpty
        guard isResting || (presentation == .peek && expandTask == nil) || liftedAndFree else {
            // Shows as the island closes. News about what the island shows, like the timer ending on its tab, was
            // seen there and only keeps for its own time; other news the owner must see waits as long as it takes.
            // Open, the island shows one tab, so a live activity on another tab hasn't been seen.
            let isAboutWhatShows = presentation == .expanded
                ? selectedTab == peek.source
                : liveActivities.contains { $0.id == peek.source }
            line(up: peek, until: peek.mustBeSeen && !isAboutWhatShows ? nil : .now + peek.duration,
                 seenOnItsTab: presentation == .expanded && isAboutWhatShows)
            return
        }
        presentPeek(peek)
    }

    /// Shows the next waiting peek if someone can see the island now and it is at rest. Called whenever that may have
    /// changed, such as when the display wakes or the screen unlocks.
    func visibilityMayHaveChanged() {
        isOutOfSight = !canBeSeen()
        updateVisibility()
        guard isResting, !isOutOfSight, let next = nextWaitingPeek() else { return }
        presentPeek(next)
    }

    /// Nobody can see the island any more: the screen locked, the display slept. Peeks the owner must see wait for them
    /// again, a showing one too, to show in full once someone can; the others would be missed anyway.
    func islandWentOutOfSight() {
        isOutOfSight = true
        updateVisibility()
        keepWaitingOnlyForWhatMustBeSeen()
        guard presentation == .peek, peek?.mustBeSeen == true else { return }
        cancelPendingTransitions()
        present(resting)
    }

    /// At rest, a peek can show without interrupting anyone.
    var isResting: Bool { presentation == .idle || presentation == .compact }

    private func updateVisibility() {
        // Hidden for a full-screen app, the island still shows while it is out for a peek, and while that is open.
        let visible = !isOutOfSight && (!isHidden || !isResting)
        if visible != isVisible { isVisible = visible }
    }

    /// Watches the pointer only while hover waits for it to leave a peek it never came for.
    private func updatePointerWatch() {
        let watch = hoverHeldOff && peekKeepsItsTime
        guard watch != isWatchingPointer else { return }
        isWatchingPointer = watch
        watchesPointer?(watch)
    }

    /// Drops the waiting peeks only whoever was looking would want, and puts a showing peek the owner must see back at
    /// the front. Those that wait wait as long as it takes, since nobody has seen them yet.
    private func keepWaitingOnlyForWhatMustBeSeen() {
        waiting = waiting.filter(\.peek.mustBeSeen).map { WaitingPeek(peek: $0.peek, until: nil) }
        if presentation == .peek, let peek, peek.mustBeSeen {
            waiting.insert(WaitingPeek(peek: peek, until: nil), at: 0)
        }
    }

    /// Puts `peek` in line, behind the others the owner must see if it is one, otherwise at the back. With no deadline
    /// it waits as long as it takes.
    private func line(up peek: Peek, until: ContinuousClock.Instant?, seenOnItsTab: Bool = false) {
        let entry = WaitingPeek(peek: peek, until: until, seenOnItsTab: seenOnItsTab)
        if peek.mustBeSeen, let firstOther = waiting.firstIndex(where: { !$0.peek.mustBeSeen }) {
            waiting.insert(entry, at: firstOther)
        } else {
            waiting.append(entry)
        }
    }

    /// The island closing is when waiting peeks are judged: those still fresh then show in turn after `first`. One that
    /// only keeps for a while keeps it from when its turn comes, rather than spend it behind the ones ahead, like Keep
    /// Awake's turning off behind the low-battery warning that turned it off.
    private func giveWaitingPeeksTheirTurn(after first: Peek) {
        var turn = ContinuousClock.now + first.duration
        waiting = waiting.map { entry in
            defer { turn += entry.peek.duration }
            return WaitingPeek(peek: entry.peek, until: entry.until.map { _ in turn + entry.peek.duration },
                               seenOnItsTab: entry.seenOnItsTab)
        }
    }

    /// The first waiting peek still worth showing, dropping any whose time has passed.
    private func nextWaitingPeek() -> Peek? {
        let now = ContinuousClock.now
        waiting.removeAll { $0.until.map { $0 <= now } ?? false }
        return waiting.isEmpty ? nil : waiting.removeFirst().peek
    }

    /// Shows `peek` from whatever the island shows now, and closes it after its duration.
    private func presentPeek(_ peek: Peek) {
        // Only a pending close gives way; a hover in progress still opens the island.
        collapseTask?.cancel()
        peekTask?.cancel()
        present(.peek) { self.peek = peek }
        defer { center.peekWasShown(peek) }
        // A pointer the peek grew under didn't come for it, and only reports arriving once it moves. Any other pointer
        // has gone, even if a close it started was just cancelled, so hover counts for it.
        peekKeepsItsTime = !pointerRegions.isEmpty || isPointerOnIsland()
        hoverHeldOff = peekKeepsItsTime
        if peekKeepsItsTime { Logger.island.notice("peek came under the pointer") }
        peekEnds = .now + peek.duration
        peekTask = Task { [weak self] in
            // Without a tolerance the system may stretch a 5 s peek by half a second (measured: 342 ms).
            try? await Task.sleep(for: peek.duration, tolerance: Motion.timerTolerance)
            // Only a peek closes this way, never an island that has opened since, and never from under the pointer:
            // one resting on the peek keeps it, or hovers it open.
            guard !Task.isCancelled, let self, presentation == .peek, pointerRegions.isEmpty else { return }
            settle()
        }
    }

    private var resting: IslandPresentation { liveActivities.isEmpty ? .idle : .compact }

    /// The tab the island opens on: the most important live activity's, or with none live, the tab of the one started
    /// last, and before anything has started the first.
    private var tabOnOpening: String? {
        let tabs = self.tabs
        let hasTab = { (id: String) in tabs.contains { $0.id == id } }
        if let live = liveActivities.first(where: { hasTab($0.id) }) { return live.id }
        if let lastStartedTab, hasTab(lastStartedTab) { return lastStartedTab }
        return tabs.first?.id
    }

    private func pointerArrived() {
        collapseTask?.cancel()
        switch presentation {
        case .idle, .compact:
            present(.lifted)
            scheduleExpand()
        case .lifted, .peek:
            if expandTask == nil, !hoverHeldOff { scheduleExpand() }
        case .expanded:
            break
        }
    }

    private func pointerLeft() {
        cancelExpand()
        guard !isResting else { return }
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: Motion.exitGrace, tolerance: Motion.timerTolerance)
            guard !Task.isCancelled, let self else { return }
            // The pointer has really gone, so hover counts again.
            hoverHeldOff = false
            // A peek that grew under the pointer keeps its own time, unless that ran out while the pointer rested on it.
            if presentation == .peek, peekKeepsItsTime, let peekEnds, peekEnds > .now { return }
            settle()
        }
    }

    /// Closes the island, showing a held peek on the way if it is still fresh. The island never vanishes from under a
    /// resting pointer: while a hover is about to open it, it stays as it is, and otherwise it stops at the lifted pill.
    /// Today nothing settles the island with the pointer on it: the pointer's arrival cancels a pending close, and a
    /// peek whose time runs out under the pointer stays. The pointer checks keep the promise should a new path ever
    /// settle it anyway.
    private func settle() {
        let isClosing = presentation != .peek
        if canBeSeen(), let next = nextWaitingPeek() {
            if isClosing { giveWaitingPeeksTheirTurn(after: next) }
            presentPeek(next)
            return
        }
        if pointerRegions.isEmpty {
            present(resting)
        } else if expandTask == nil {
            present(.lifted)
            if !hoverHeldOff { scheduleExpand() }
        }
    }

    private func liveActivityDidChange() {
        let live = center.liveActivities
        guard live.map(\.id) != liveActivities.map(\.id) else { return }
        // A start is an activity joining the live ones. Keep Awake turned back on from the menu bar within its 0.3 s of
        // closing never leaves them, so it goes unrecorded; the tab's own Turn On only appears after it has left.
        let wasLive = Set(liveActivities.map(\.id))
        if let started = live.first(where: { $0.hasTab && $0.countsAsStarted && !wasLive.contains($0.id) }) {
            lastStartedTab = started.id
        }
        let next: IslandPresentation = isResting ? (live.isEmpty ? .idle : .compact) : presentation
        if next == .expanded { pressesAimAtOldContent = true }
        // A pointer resting on the lifted island or a peek keeps the old activity's room, so the island doesn't narrow
        // from under it.
        let room = !pointerRegions.isEmpty && (next == .lifted || next == .peek) ? compactSlotWidth : nil
        present(next) {
            if let room { self.heldSlotWidth = room }
            self.liveActivities = live
        }
    }

    private func scheduleExpand() {
        let intent = hoverIntent
        expandTask = Task { [weak self] in
            try? await Task.sleep(for: intent, tolerance: Motion.timerTolerance)
            guard !Task.isCancelled, let self else { return }
            expandTask = nil
            // A close still pending would otherwise fold the island under the pointer.
            collapseTask?.cancel()
            present(.expanded)
        }
    }

    private func cancelExpand() {
        expandTask?.cancel()
        expandTask = nil
    }

    private func cancelPendingTransitions() {
        cancelExpand()
        collapseTask?.cancel()
    }

    private func present(_ next: IslandPresentation, alongside changes: () -> Void = {}) {
        // The island window stops tracking the pointer once idle, so it can't report leaving.
        if next == .idle { pointerRegions.remove(.island) }
        // Back at rest, nothing holds off hover any more; the pointer leaving clears it too (`pointerLeft`).
        if next == .idle || next == .compact { hoverHeldOff = false }
        // Only the open island's new content needs guarding, so the guard ends when the island closes.
        if next != .expanded { pressesAimAtOldContent = false }
        // A peek's own time ends with the peek.
        if next != .peek {
            peekTask?.cancel()
            peekKeepsItsTime = false
        }
        if next != presentation {
            Logger.island.notice("""
                \(String(describing: self.presentation), privacy: .public) → \(String(describing: next), privacy: .public)
                """)
            onPresentationChange?(presentation, next)
        }
        let opening = next == .expanded && presentation != .expanded
        withAnimation(Motion.animation(from: presentation, to: next)) {
            // At rest or open, the island no longer keeps room for the pointer.
            if next != .lifted && next != .peek { heldSlotWidth = nil }
            changes()
            // After the changes, so a tab follows the activities that are live as the island opens.
            if opening { selectedTab = tabOnOpening }
            presentation = next
        }
        if opening {
            if let selectedTab { Logger.island.notice("opened on the \(selectedTab, privacy: .public) tab") }
            // Open, the island shows one tab. News the owner must see about anything else hasn't been seen, so it waits
            // as long as it takes, even if it lined up while the hover was about to open the island, when all that was
            // live still showed beside the notch. News the owner saw on its own tab before stays seen.
            waiting = waiting.map { entry in
                guard entry.peek.mustBeSeen, !entry.seenOnItsTab, entry.peek.source != selectedTab else { return entry }
                return WaitingPeek(peek: entry.peek, until: nil)
            }
        }
        // Hidden for a full-screen app, the island is only on screen while it is out.
        updateVisibility()
    }
}

/// A peek waiting for its turn, and until when it stays worth showing; with no deadline, as long as it takes.
private struct WaitingPeek {
    var peek: Peek
    var until: ContinuousClock.Instant?
    /// Lined up while the open island showed its activity's tab, so the owner saw the news there: it keeps its deadline,
    /// whichever tab the island opens on next.
    var seenOnItsTab = false
}
