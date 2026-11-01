# Changelog

All notable changes to Jambul are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Jambul uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
The first public release.

### Added
- The island around the notch. Hover opens it, moving away closes it, and a click toggles it; it lifts under a resting pointer, with haptic taps on the trackpad and Reduce Motion support.
- Timer: 5, 15 or 25 minutes, with a ring and the time left beside the notch, +1 minute, pause and stop. When it ends there's a peek, a sound and a haptic tap. An end that falls while the Mac sleeps waits for a full wake, and the peek waits for an unlocked screen.
- Keep Awake: keeps the display on until turned off, with a blinking eye and a typing laptop beside the notch. It turns itself off at 20% battery, and stays on when Jambul is relaunched by a build.
- Battery peeks for plugging and unplugging the charger and a full battery, and low-battery warnings at 20% and 5% that wait until someone can see them.
- Several activities at once: the two most important share the compact island.
- The open island shows one feature per tab and opens on what's running, or on what was started last.
- Day and time beside the notch while a full-screen app hides the menu bar, and an option to hide the island in full screen.
- Settings: open at login, hover speed, haptic taps and the timer's sound.
