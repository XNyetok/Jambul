# Changelog

All notable changes to Jambul are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Jambul uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- The tabs go Home, Usage, Keep Awake and Timer, and Home's cards follow the same order, with the battery's last.

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

[Unreleased]: https://github.com/XNyetok/Jambul/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/XNyetok/Jambul/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/XNyetok/Jambul/releases/tag/v0.1.0
