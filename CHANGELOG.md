# Changelog

All notable changes to Jambul are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Jambul uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Claude Code's Done and Stopped peeks show a check that draws itself and an exclamation mark instead of an eye.

## [0.4.0] - 2026-11-14
A livelier island: the glyph beside the notch travels into the open island, activities take turns there, and Jambul now needs macOS 27.

### Added
- As the island opens, the glyph beside the notch travels to its place on the tab or on Home, and back as it closes.
- With more than two activities running, the ones that didn't fit beside the notch take turns on its left.

### Changed
- Jambul now needs macOS 27 or later.
- Tab symbols are easier to read and take color only while their activity is running, cards on Home dim while theirs is off, and the Usage tab's columns line up.
- Beside the notch, each side of the island is only as wide as what it shows, and the timer's and Keep Awake's tabs are larger.
- Numbers roll as they change, a working session's ring turns a step at a time, a failed turn's eye shakes its head, and the island opens with less bounce.

## [0.3.0] - 2026-11-13
Claude Code's sessions in the island, and tabs on both sides of the camera.

### Added
- Claude Code sessions: see which sessions work, need you or are done beside the notch and in their own tab, with a peek when one needs your permission or an answer, finishes or stops on an error, and keep the display awake until they finish.

### Changed
- The open island's tabs sit on both sides of the camera, and in full screen the day and time show right below it.

### Fixed
- The open island no longer has a shadow, which ended in a visible line a little below it.
- Antigravity's usage now shows up after login, when Jambul starts before the network is ready.

## [0.2.1] - 2026-11-13
Fixes for clicks around the island and for Claude's usage, and a new tab order.

### Changed
- The tabs go Home, Usage, Keep Awake and Timer, and Home's cards follow the same order, with the battery last.

### Fixed
- Clicks below and beside the island now reach the app underneath while something shows beside the notch, like a running timer.
- When Jambul starts with something already beside the notch, hovering or clicking the island there works right away.
- Claude's usage now follows when a limit is handed back before its window ends, instead of holding the old, higher number until the reset.

## [0.2.0] - 2026-11-02
Usage limits for your AI subscriptions, and Home.

### Added
- Usage limits: a tab with how much of your Claude, Antigravity and Codex limits you've used and when they reset, with each service's logo. Peeks warn at 80% and 95%, the island stays beside the notch from 95% until the limit resets, and a peek says when it's back. Each service can be turned on or off in Settings, and Codex starts off. Claude's numbers come through Claude Code's status line, which Jambul joins only after you agree and leaves exactly as it was when you turn Claude off.
- Home: the open island's first tab, where it opens as Jambul starts, with a card for the timer, Keep Awake, the battery and the usage limits. Click the timer, Keep Awake or usage card to open its tab. The tab buttons narrow a little so four fit beside the notch.

### Changed
- The island opens on the tab you looked at last, instead of on what's running or what you started last.

## [0.1.0] - 2026-11-01
The first public release.

### Added
- The island around the notch. Hover opens it, moving away closes it, and a click toggles it; it lifts under a resting pointer, with haptic taps on the trackpad and Reduce Motion support.
- Timer: 5, 15 or 25 minutes, with a ring and the time left beside the notch, +1 minute, pause and stop. When it ends there's a peek, a sound and a haptic tap. An end that falls while the Mac sleeps waits for a full wake, and the peek waits for an unlocked screen.
- Keep Awake: keeps the display on until turned off, with a blinking eye and a typing laptop beside the notch. It turns itself off at 20% battery, and stays on when Jambul is relaunched by a build.
- Battery peeks for plugging and unplugging the charger and a full battery, and low-battery warnings at 20% and 5% that wait until someone can see them.
- Several activities at once: the two most important share the compact island.
- The open island shows one feature per tab and opens on what's running, or on what was started last.
- Day and time beside the notch while a full-screen app hides the menu bar, written as the locale writes them and shortened where a 12-hour clock needs the room, and an option to hide the island in full screen.
- Settings: open at login, hover speed, haptic taps and the timer's sound.

[Unreleased]: https://github.com/XNyetok/Jambul/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/XNyetok/Jambul/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/XNyetok/Jambul/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/XNyetok/Jambul/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/XNyetok/Jambul/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/XNyetok/Jambul/releases/tag/v0.1.0
