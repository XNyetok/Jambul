# Architecture

Jambul is a background app (no Dock icon) that draws a Dynamic Island–style island around the MacBook notch. AppKit owns the app's lifecycle and windows; SwiftUI draws the island. This page explains how the pieces fit and why they're built the way they are.

## Windows and the pointer
- AppKit owns lifecycle and windows (`App/main.swift`, `AppDelegate`, `IslandPanel`); SwiftUI draws the island inside them.
- Two panels split the pointer work. A notch-sized hot-zone panel listens all the time. The island panel (`IslandPanelFitter`) ignores the mouse while the island is idle, so nothing outside the notch blocks clicks then. Out, it takes the mouse, and once the island has settled, resting beside the notch, as a peek or lifted, it shrinks to the island's own frame, so the apps below and beside the island keep their clicks, also while an activity rests beside the notch for hours. It takes the whole canvas back right before the island changes, and keeps it while the island is open. Right after a change, while the island settles, the canvas still takes clicks around it.
- A window that takes the mouse takes every click across its frame, clear pixels too, once its `ignoresMouseEvents` has been set (measured). Left unset, clicks fall through clear pixels, but hover goes unreported when the pointer reaches the drawn part across clear ones. So a panel's frame is what limits where it takes clicks.
- The island's view keeps the canvas's size and place on screen whatever the panel's frame, so SwiftUI never lays it out again as the panel changes (measured: not one frame out of place in 120 changes). The panel only shrinks once every spring has settled (`Motion.islandSettles`), and grows as the model announces a change, before storing any of it (`IslandModel.onWillChange`): resized while a change was being stored, it made SwiftUI draw the island as it was and miss the change. It also waits for a pointer resting on the island to move off before shrinking: shrunk under it, it made SwiftUI see the pointer leave and come back.
- Distributed notifications (`com.apple.screenIsLocked` and the like) are observed with `suspensionBehavior: .deliverImmediately`. AppKit holds them back while the app isn't active, which for Jambul is nearly always.

## The island's state machine
`IslandModel` (`@Observable`) is the island's state machine, and views are a pure function of it. The island is `idle` behind the notch, `compact` with a live activity beside the notch, `lifted` while the pointer rests on it, showing a `peek`, or `expanded`.

Hover opens the island after a short intent delay, leaving closes it, and a click toggles it. Closing by click folds the island back to its lifted pill while the pointer stays, and hover leaves it closed until the pointer goes away. The island never vanishes from under a resting pointer, and a click always visibly does something. There are no swipe gestures: they stalled once the island shrank away from the pointer.

## Activities
- Features are `IslandActivity` conformers in `Activities/`, registered with `ActivityCenter` in `AppDelegate` (`registerJambulsActivities`). Today these are Home, the usage limits, Claude Code's sessions, Keep Awake, the timer and the battery, plus a demo activity in debug builds. The order they register in is the order of the tabs and of Home's cards.
- The two most important live activities share the compact island; the second shows only its `compactMinimal` glyph, on the left.
- The open island shows one activity's `tab` at a time, with the tabs split between the two sides of the camera, the extra one on the left (`IslandLayout.tabSides`). Each side lines up with the edge of the content below it. An activity without one, like the battery or the debug demo, gets no tab. With more tabs than fit on a side at full width, each narrows to fit, and the island keeps its size (`IslandLayout.tabButtonWidth`).
- Home (`HomeActivity`), registered first, is the first tab: one card for each activity with a `homeCard`, laid out by `HomeCardContent`. A click on a card opens that activity's tab. An activity can keep its card off Home while it has nothing to say (`showsHomeCard`), like the battery before its first reading.
- The island first opens on Home, and from then on on the tab it showed last. Only a click changes the tab, on a tab or on a card on Home; activities starting, running or ending leave it where it is, since what's live already shows beside the notch. Nothing is remembered across launches, so each launch starts on Home.
- Each activity has a `tint` for its glyphs and buttons. Its tab's symbol takes color only while something is going on (`tabTint`), and a card on Home dims while its activity is off (`homeCardIsQuiet`).
- While a full-screen app hides the menu bar, the open island shows the day and time right below the camera, a row taller so a tab keeps its room (`IslandLayout.clockRowHeight`).

## Peeks
- Activities post short messages as a `Peek` through `ActivityCenter`.
- A peek that arrives while the island is open, or while a hover is about to open it, waits and shows as the island closes (after a click-close, once the pointer leaves), if it is still fresh by then.
- Must-see news about something the island doesn't show (when open, anything but the chosen tab) waits however long the island stays open. Home's cards don't count as showing it: they don't say what happened.
- A peek marked `mustBeSeen` ("Timer done", low battery) also waits while nobody can see the island (display asleep, screen locked), and comes out even while the island is hidden for a full-screen app. Other peeks are dropped then.
- Waiting peeks stand in one line, must-see first. No other activity's peek cuts a must-see one short, and a newer peek from the same activity (`Peek.source`) replaces its own.

## Motion and drawing
- Every animation parameter lives in `Island/Motion.swift`. Views don't define their own springs.
- Always-on ambient animations (visualizers, pulses) use Core Animation rather than repeating SwiftUI animations; on a MacBook Air that measured about 8–10× less CPU. Core Animation moves the cost rather than removing it, though: a continuous animation still cost WindowServer about 16 CPU points.
- Displays that change slowly, like the timer's countdown, redraw once a second with `TimelineView(.periodic)` and no animation (about 0.35% CPU). Rolling digits and `ProgressView(timerInterval:)` both drew at 60 fps.
- Keep Awake's eye and laptop move on one shared beat (`KeepAwakeBeat`), so Jambul wakes once for both.
- Views that redraw by themselves hold still while nobody can see the island (`IslandModel.isVisible`).

## Usage limits
- `UsageActivity` holds the last reading of each subscription and the time each limit starts over. It sits beside the notch from 95%, and posts peeks at 80% and 95%, at 100% and when a limit that reached 95% starts over.
- Each warning is recorded only once the island has shown its peek (`ActivityCenter.peekWasShown`), so a peek nobody saw is asked for again. A window is told from the next by its reset time, and times within 30 minutes count as the same window, since a provider can move it a little between readings. Each Claude Code session repeats the limits it last heard, for hours if it sits idle, so within a window only a session that just made a request changes Claude's numbers. Two sessions at work can be a point apart, so a number only drops once it is lower by more than two points: a provider can hand usage back before the window ends.
- Nothing polls. Each source waits for something to happen:
  - **Claude:** Claude Code's status line becomes a short shell line that hands its input to `InputSocket`, a Unix socket in a folder only the owner can open, with macOS's own `nc`, then runs the owner's status line unchanged (`ClaudeStatusLineInstaller`). It names no path into Jambul, so moving or deleting Jambul breaks nothing.
  - **Antigravity:** `agy -p /usage --output-format json` (about 6 s), once as Jambul starts or Antigravity is turned on, then when the Usage tab or Home opens with numbers older than 5 minutes, when the Mac wakes, and while agy writes its log (FSEvents), at most once per 5 minutes. Its output goes to a file, and a run that hangs is stopped after 30 s, killed if it must. A run that fails is tried once more as soon as the Mac is online (`OnlineWait`): right after login the network isn't up yet, and agy then waits for a sign-in.
  - **Codex:** the `rate_limits` named "codex" that Codex writes into its session logs, read from the end of a log whenever FSEvents reports a change, and dated by when the log was written.
- One wait at a time, for the next limit to start over.
- The logos are their owners' trademarks (see `THIRD_PARTY_NOTICES.md`). Every usage motion plays once, except Claude's logo while Claude Code works: it turns one ray on a 2 s beat, holding still in between, and only while the open island shows it. Claude Code also sends its status line on a timer, so "working" means a session's request time grew in the last 20 s.

## Claude Code sessions
- Once the owner agrees in Settings, `AgentHookInstaller` adds one command hook to each of ten events in `~/.claude/settings.json` (`ClaudeSettingsFile`, shared with the status line). Jambul knows its own by their `JAMBUL_AGENT=1` prefix and never touches anyone else's.
- Each hook pipes the app Claude Code runs in (`$__CFBundleIdentifier`) and the hook's input into a second `InputSocket` with `nc` in the background, and returns at once: about 10 ms per hook (measured). Like the status line, it names no path into Jambul.
- An input past the socket's limit arrives cut to its start, where Claude Code puts the session and the hook's name (`AgentEvent`).
- `AgentActivity` keeps each session in memory: working, waiting on the owner (a permission or a question), done, failed or stopped. It sits beside the notch while a session works, ahead of everything else while one waits on the owner.
- Claude Code runs no hook when a turn is stopped with Esc. A session quiet mid-turn has the end of its transcript read a minute later, and every few minutes while it stays quiet; Esc leaves "[Request interrupted by user" there. A working session quiet in its hooks and its transcript for 20 minutes counts as stopped. A session waiting on the owner never goes stale.
- "Needs you" must be seen, and is taken back while it waits (`ActivityCenter.withdrawPeeks`) once the request is answered in the terminal. "Done" stays quiet for a turn under a minute that the owner watched in its terminal, and while another session waits on the owner.
- Keep Awake can stay on until the last working session finishes (`KeepAwakeActivity.agentsFinished`).
- Nothing about sessions is saved; the log only records changes of state, never what an agent said or which files it touched.

## Sleep
Anything due while the Mac sleeps waits for `NSWorkspace.didWakeNotification` before it shows or sounds. `Task.sleep` counts sleep time and can fire in a dark wake, with the display off and no audio; `didWake` only comes on a full wake.

## Geometry
- The notch can sit on a half point (x = 645.5 on a 13-inch MacBook Air), while AppKit snaps window origins down to whole points. So panels are framed on whole points, and the notch shape is placed inside them (`NotchGeometry.panelFrame`, `hotZoneFrame`).
- Beside the notch, each side of the island is as wide as what it holds (`compactLeadingWidth`, `compactSlotWidth`), so its content sits close to the camera and the island's middle can sit off the notch's (`IslandLayout.xOffset`). A peek and the open island are centered.
- The compact island is as tall as the menu bar band (33 pt on that MacBook Air). The band hides the camera housing, and full-screen windows start right below it (measured: y = 33), so the island never covers them.
- Its content sits as far from the drawn sides as from the top and bottom (8.5 pt there), as Apple asks for in the Dynamic Island. The top flares make the drawn body 6 pt narrower than the frame on each side, so margins are measured from the drawn edge (`IslandLayout.compactMargin`).

## Settings and system state
- Settings live in `Preferences` (`@Observable`, saved to `UserDefaults` on each change), and `IslandController` applies them.
- Full-screen detection is `SpaceInspector`, which reads SkyLight's Space type (4 is full screen) on each Space change. SkyLight is a private framework, so it is loaded at runtime, and if it ever goes away every Space reads as a regular desktop.

## Buttons inside the island
- Buttons inside the island fire on the first click and don't reach the island's own tap. They're styled with `IslandButtonStyle`, whose fill is the hit area.
- They never use `.disabled`: a disabled button passes the click through to the island's toggle.
- Tabs use `IslandTabButtonStyle`, whose capsule is the hit area, though only the chosen tab draws it.
- Home's cards are buttons whose whole card is the hit area. The battery's card has no tab to open, so it isn't a button, and a click on it toggles the island like a click on any other part of it.
- A control that gives way to another in the same spot, like Keep Awake's Stop to Turn On, swaps only as the live activities change. That arms the guard against the rest of a double click (`IslandModel.acceptsPress`).
