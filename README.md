# Jambul

[![CI](https://github.com/XNyetok/Jambul/actions/workflows/ci.yml/badge.svg)](https://github.com/XNyetok/Jambul/actions/workflows/ci.yml)

A Dynamic Island for your MacBook's notch: small, quiet and fast.

Jambul turns the notch into a living island. Hover over it to open it, move away to close it, or click to toggle. Activities that are running rest beside the notch, and short messages, called peeks, slide out when something happens.

## Features
- **Timer:** start 5, 15 or 25 minutes from the island. A ring and the time left rest beside the notch; open the island to add a minute, pause or stop. When it ends you get a peek, a sound and a tap on the trackpad. If the Mac was asleep, the timer ends once it fully wakes; if the screen was locked, the peek waits until you unlock it.
- **Keep Awake:** keeps the display on until you turn it off, for long downloads, builds or coding agents. A blinking eye and a typing laptop show it's on. It turns itself off at 20% battery.
- **Battery:** peeks when the charger is plugged in or out and when the battery is full, plus low-battery warnings at 20% and 5% that wait until you can see them.
- **Usage limits:** how much of your Claude, Antigravity and Codex limits you've used and when they start over, each with its own logo. Peeks warn at 80% and 95%, the island stays beside the notch from 95% until the limit resets, and a peek tells you when it's back. Each subscription can be turned on or off in Settings; Codex starts off.
- **Home and tabs:** the open island shows one feature at a time. As Jambul starts it opens on Home, with a card for your usage limits, Keep Awake, the timer and the battery; click the usage, Keep Awake or timer card to open its tab. After that it opens on the tab you looked at last.
- **Full screen friendly:** the island never covers a full-screen app, and shows the day and time while the menu bar is hidden. It can also hide completely in full screen.
- **Settings:** open at login, hover speed, haptic taps, the timer's sound, and which usage limits to show. Reduce Motion is respected.

## Requirements
- macOS 14 Sonoma or later.
- Made for MacBooks with a notch. On other screens the island appears when you move the pointer to the top center.

## Install
1. Download the latest `Jambul-<version>.zip` from [Releases](https://github.com/XNyetok/Jambul/releases), unzip it, and move `Jambul.app` to Applications.
2. Optionally, check the download against its checksum: `shasum -a 256 -c Jambul-<version>.zip.sha256`.
3. Open Jambul. It isn't notarized by Apple yet, so macOS refuses to open it the first time. Go to System Settings → Privacy & Security, find the message about Jambul, and choose **Open Anyway**.

Jambul lives in the notch and in the menu bar (the bird icon), not in the Dock.

## Build from source
You need Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Contributors also need [gitleaks](https://github.com/gitleaks/gitleaks) (`brew install gitleaks`).

```sh
git clone https://github.com/XNyetok/Jambul.git
cd Jambul
./scripts/setup.sh   # installs the git hooks that keep secrets out of commits
./scripts/run.sh     # builds a debug build and launches it
./scripts/test.sh    # runs the unit tests
```

## Privacy
Jambul makes no network connections and collects no data. Its settings stay in its preferences on your Mac. To tell full-screen spaces apart it reads SkyLight, a private macOS framework, at runtime; if that ever stops working, Jambul treats every space as a regular desktop instead of failing.

For usage limits, Jambul only reads what the tools on your Mac already know:
- **Claude:** once you agree in Settings, Jambul adds itself to Claude Code's status line in `~/.claude/settings.json`, keeping a copy of the original. Your status line looks the same; it also hands its input to Jambul over a socket only your account can open. Turning Claude off puts your status line back exactly.
- **Antigravity:** Jambul runs `agy -p /usage --output-format json`, Antigravity's own usage report, which sends no prompt to a model. agy asks Google for the numbers itself.
- **Codex:** Jambul reads the limits Codex writes into its session logs in `~/.codex/sessions`.

Jambul never reads a login token.

## Performance
Jambul aims for about 0% CPU while idle and less than 30 MB of memory. It reacts to system events instead of polling. Anything that keeps moving on its own either moves in short steps on a beat, holding still in between, or uses Core Animation, and it pauses while nobody can see the island.

## Contributing
Bug reports, ideas and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first, and see the [roadmap](docs/ROADMAP.md) and the [architecture notes](docs/ARCHITECTURE.md). Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

To report a security problem, see [SECURITY.md](SECURITY.md); please don't open a public issue for it.

## License
Jambul is released under the [MIT License](LICENSE).
