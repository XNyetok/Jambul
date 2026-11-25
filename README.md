# Jambul

[![CI](https://github.com/XNyetok/Jambul/actions/workflows/ci.yml/badge.svg)](https://github.com/XNyetok/Jambul/actions/workflows/ci.yml)

A notch utility for macOS: small, quiet and fast.

Jambul turns the notch into a living island. Hover over it to open it, move away to close it, or click to toggle. Activities that are running rest beside the notch, and short messages, called peeks, slide out when something happens.

## Features
- **Timer:** start 1, 5, 10, 15, 25, 45 or 60 minutes from round buttons in the island; the one under the pointer shows on a dial with when it would end. A small dial and the time left rest beside the notch; open the island to add a minute, pause or cancel. When it ends you get a peek, a sound and haptic taps on the trackpad. If the Mac was asleep, the timer ends once it fully wakes; if the screen was locked, the peek waits until you unlock it.
- **Keep Awake:** keeps the display on until you turn it off, for long downloads, builds or coding agents. A pair of eyes opens, blinks and falls asleep with it, and how long it has been on shows beside the notch. It turns itself off at 20% battery (or 5%, if you turned it on below 20%) or, when you choose Until Done, once the monitored coding sessions finish.
- **Battery:** peeks when the charger is plugged in or out and when the battery is full, plus low-battery warnings at 20% and 5% that wait until you can see them.
- **Usage limits:** how much of your Claude and Codex limits you've used and when they start over. Peeks warn at 80% and 95% and when a limit runs out, and a peek tells you when it's back. Each subscription can be turned on or off in Settings; Codex starts off. Automatic Antigravity usage checks via headless `agy -p` are paused.
- **Coding sessions.** Follow Claude Code, Codex and Antigravity in one Sessions tab and one indicator beside the notch. Peeks show confirmed requests for your attention and how turns end. Enable each client in Settings. For Codex, review Jambul's hooks in `/hooks` and start or reopen a local session. Codex needs a reachable shared App Server for live approval and question status. Reopen `agy` to load its hooks and status line.
- **Home and tabs:** the open island shows one feature at a time. As Jambul starts it opens on Home, with a card for your usage limits, coding sessions, Keep Awake, the timer and the battery; click a card to open its tab. After that it opens on the tab you looked at last.
- **Full screen friendly:** at rest the island never covers a full-screen app, and opened there it shows the day and time the hidden menu bar would. It can also hide completely in full screen; news you must see, like a timer ending, still shows.
- **Settings:** open at login, hover speed, haptic taps, the timer's sound, coding sessions, and which usage limits to show. Reduce Motion is respected.

## Requirements
- macOS 27 or later.
- Made for MacBooks with a notch. On other screens the island appears when you move the pointer to the top center.

## Install
1. Download the latest `Jambul-<version>.zip` from [jambul.web.id](https://jambul.web.id) or [Releases](https://github.com/XNyetok/Jambul/releases), unzip it, and move `Jambul.app` to Applications.
2. Optionally, check the download against its checksum: `shasum -a 256 -c Jambul-<version>.zip.sha256`.
3. Open Jambul. It isn't notarized by Apple yet, so macOS refuses to open it the first time. Go to System Settings → Privacy & Security, find the message about Jambul, and choose **Open Anyway**.

Jambul lives in the notch and in the menu bar, not in the Dock.

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
Jambul itself makes no network connections and collects no data. For Codex usage limits it runs the local Codex CLI, which contacts its own service, as described below. Its settings stay in its preferences on your Mac. To tell full-screen spaces apart it reads SkyLight, a private macOS framework, at runtime; if that ever stops working, Jambul treats every space as a regular desktop instead of failing.

For Claude Code's sessions, once you agree in Settings, Jambul adds hooks to `~/.claude/settings.json`, keeping a copy of the original and leaving your other hooks as they are. Each hook hands what Claude Code tells it to Jambul over a socket only your account can open, and returns at once. When a session goes quiet in the middle of a turn, Jambul reads the end of its transcript to see whether you stopped it. Turning the sessions off takes Jambul's hooks out again.

For Codex and Antigravity, Jambul's hooks relay session identifiers and status metadata over the same local socket. Codex's hooks live in `$CODEX_HOME/hooks.json` (`~/.codex/hooks.json` by default). Jambul reads status from the shared local Codex App Server when it is reachable, or reads turn markers from a session's local rollout when available. Antigravity's hooks live in `~/.gemini/config/hooks.json`. Jambul joins the `agy` status line to see when its confirmation dialog is open and preserves the user's status line output. Turning either client off removes Jambul's hooks and restores the status line it joined.

Jambul gets usage limits from the tools on your Mac.
- **Claude:** once you agree in Settings, Jambul adds itself to Claude Code's status line in `~/.claude/settings.json`, keeping a copy of the original. Your status line looks the same; it also hands its input to Jambul over a socket only your account can open. Turning Claude off puts your status line back exactly.
- **Antigravity:** automatic usage checks via `agy -p /usage` are currently paused; Antigravity coding sessions continue to use local hooks and the status line.
- **Codex** uses the CLI’s existing sign-in to fetch account limits without sending a prompt. Jambul also reads the limits Codex writes to its local session logs.

Jambul never reads a login token.

## Performance
Jambul aims for about 0% CPU while idle and less than 30 MB of memory. It reacts to system events instead of polling. Anything that keeps moving on its own either moves in short steps on a beat, holding still in between, or uses Core Animation, and it pauses while nobody can see the island.

## Contributing
Bug reports, ideas and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first, and see the [roadmap](docs/ROADMAP.md) and the [architecture notes](docs/ARCHITECTURE.md). Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

To report a security problem, see [SECURITY.md](SECURITY.md); please don't open a public issue for it.

## License
Jambul is released under the [MIT License](LICENSE).

Jambul is an independently developed macOS utility. Third-party product names identify the tools referenced in Jambul and belong to their respective owners. Jambul is not affiliated with, endorsed by, or sponsored by Apple, Anthropic, Google, or OpenAI.
