# Roadmap

Where Jambul is and where it's heading. Plans change as we learn; open an issue if there's something you'd like to see.

## Principles
- **Native and light.** Swift, AppKit for windows, SwiftUI for drawing. Anything that keeps moving on its own does so in short steps on a beat, or with Core Animation. Idle CPU ≈ 0%, memory under 30 MB, no polling.
- **Apple-like.** Black and minimal; Jambul's character comes through small interactions.
- **Calm interaction.** Hover opens, moving away closes, a click toggles. No swipe gestures.
- **macOS 27 and later**, so Jambul can use the system's current components.

### Motion
1. Nothing pops in: every change uses a spring that can be interrupted.
2. Opening, the shape grows first and the content follows. Closing, the content goes first and then the shape shrinks.
3. The top corners curve inward into the bezel, and the bottom corners are rounded.
4. A short hover delay (60 ms by default) keeps the island from opening by accident: past ~100 ms a wait reads as lag. Haptic taps on the trackpad as the pointer reaches the notch.
5. Reduce Motion is respected.

## Done
- **The island:** a living island around the notch, which opens on hover and click, with haptics and Reduce Motion support. It works next to full-screen apps without covering them, and on screens without a notch.
- **Timer:** 5, 15 or 25 minutes, with a ring and the time left beside the notch. It can get +1 minute, be paused or be stopped. When it ends there's a peek, a sound and a haptic tap, even if the screen was locked or the Mac asleep.
- **Battery:** peeks when the charger is plugged in or out and when the battery is full, plus low-battery warnings at 20% and 5% that wait until someone can see them.
- **Keep Awake:** keeps the display on until it's turned off, for long downloads, builds or agents, with an eye and a typing laptop beside the notch. It turns itself off at 20% battery.
- **Several activities at once:** the most important keeps the right of the compact island, and the others take turns on its left.
- **Tabs:** the open island shows one feature per tab, split between the two sides of the camera, with one color per feature. In full screen the day and time show below the camera.
- **Home:** the first tab, with a card for each feature, where the island opens as Jambul starts. After that it opens on the tab you looked at last.
- **Usage limits:** Claude, Antigravity and Codex limits in a tab with each service's logo, peeks at 80% and 95%, and the island beside the notch from 95% until a limit resets. Jambul itself still makes no network connections: it reads Claude Code's status line, Antigravity's own usage report and Codex's session logs.
- **Claude Code sessions:** which sessions work, need you or are done, beside the notch and in their own tab. A peek tells you when one needs your permission or an answer, finishes or stops on an error, and Keep Awake can stay on until they finish.
- **Motion:** as the island opens, the glyph beside the notch travels to its place in it, and back as it closes. Numbers roll as they change.
- **Open source:** a public repository with documentation and contribution guides. Every pull request is built, unit-tested and scanned for secrets and personal data. A workflow builds each release and publishes it on GitHub, starting with 0.1.0.

## Next
The next feature comes from this list:
- **Prayer times and imsakiyah:** reuses the timer, with the city chosen by hand, so no permissions or private APIs are needed.
- Calendar, AirPods and Bluetooth devices, and a file shelf with AirDrop.

## Later
- A replacement for the volume and brightness HUD, the most involved feature.
- Signed and notarized releases with automatic updates (Sparkle), once there are enough users to justify the Apple Developer Program.
- Ideas without a schedule: Indonesian localization, themes, plugins.
- On hold: Now Playing.

## Research notes
- **Now Playing:** since macOS 15.4, MediaRemote is closed to regular apps. The way in is [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3), which goes through `/usr/bin/perl` and runs a new perl process for each command; one command took 24–36 ms in a test, so play/pause wouldn't feel slow. Apple may close this gap; the fallback is AppleScript to Music, which needs the Automation permission and stable signing.
- **Music visualizer:** Core Animation alone isn't cheap enough. A continuous Core Animation animation raised WindowServer's CPU by about 16 points, so a visualizer that moves through every song would cost battery. Options: a still icon, moving only while the island is open, or a low frame rate measured first.
- **Signing before permission features:** permissions like Calendar (EventKit), Bluetooth and Accessibility are tied to the app's signature. Ad-hoc builds change signature on every build, so the permission would be asked for again and again; set up "Apple Development" signing first.
- **Shelf:** the notch's hot zone can become a drag-and-drop target while idle. [NotchDrop](https://github.com/Lakr233/NotchDrop) (MIT) is a useful reference.
- **Volume and brightness HUD:** needs the Accessibility permission to catch the media keys, so stable signing as well.
