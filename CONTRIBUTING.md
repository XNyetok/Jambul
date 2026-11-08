# Contributing to Jambul

Thanks for helping make Jambul better. Bug reports, ideas and pull requests are all welcome. Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you start
- **Bugs:** open an issue with the bug report form. Say which Mac and macOS version you use, and how to make it happen.
- **Ideas and larger changes:** open an issue first, so we can agree on the approach before you spend time on code. The [roadmap](docs/ROADMAP.md) shows what's planned.
- **Small fixes**, like typos or an obvious bug: a pull request is fine straight away.

## Setting up
You need macOS 14 or later, Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [gitleaks](https://github.com/gitleaks/gitleaks):

```sh
brew install xcodegen gitleaks
git clone https://github.com/XNyetok/Jambul.git
cd Jambul
./scripts/setup.sh
```

`setup.sh` installs the git hooks described under [Keeping secrets out](#keeping-secrets-out). Run it again whenever `.githooks/` changes.

- `./scripts/run.sh` builds a debug build and relaunches it.
- `./scripts/test.sh` runs the unit tests and shows compiler warnings, which an incremental build would hide.
- `Jambul.xcodeproj` is generated from `project.yml`. Change settings in `project.yml`, then run `xcodegen generate`. New Swift files in `Jambul/` need no project changes.
- Debug builds add a Debug submenu to the menu bar item, for trying each presentation on the real notch.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the app is put together.

## Project rules
- **Clean room.** Jambul is MIT-licensed. Never copy code from GPL projects, such as boring.notch; ideas are fine. Code under MIT, BSD or Apache-2.0 may be adapted, with its notice added to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- **macOS 14 is the deployment target.** Newer APIs go behind `if #available`.
- **Private APIs** are allowed, since Jambul ships outside the Mac App Store, but load them at runtime and fail safe, the way `SpaceInspector` does.
- **Measure, don't guess.** Check geometry and system behavior on a real Mac before relying on them.
- **Performance budget:** about 0% CPU while idle, under 30 MB of memory (60 MB with media playing). React to system events; no polling timers.
- **No lag.** Waits over about 100 ms feel slow. Every animation parameter lives in `Island/Motion.swift`, and anything that animates on its own uses Core Animation.
- **Interaction:** hover opens, moving away closes, a click toggles. The island never vanishes from under a resting pointer, and a click always visibly does something.

## Tests
- Changes to the island's state machine (`IslandModel`) need unit tests, since pointer paths are hard to exercise by hand.
- A bug fix comes with a test that fails without the fix. Check it: undo the fix, run the test, and see it fail.
- Run `./scripts/test.sh` before opening a pull request. CI runs it again.

## Keeping secrets out
Jambul's repository is public, and so is everything in its history. To keep secrets, personal data and AI attribution out of it, `./scripts/setup.sh` installs git hooks into `.git/hooks` that run [`scripts/scan.sh`](scripts/scan.sh). It reads every file straight from git and scans it whole:
- **Before each commit and merge,** the staged files and the commit message are checked against [gitleaks](https://github.com/gitleaks/gitleaks)' rules for hundreds of token and key formats, and against Jambul's own rules:
  - no home-folder paths (`/Users/<name>`), and no email addresses other than the project's public ones;
  - no AI attribution, and no markers that keep CI from running;
  - no files that must never be committed: signing material, logs and crash reports, `.env` files, local-only files;
  - no archives, PDFs, RTF documents or executables, which can't be checked for any of this.
- **Before each push,** every commit, tag and ref name the remote doesn't have yet is checked again: files, messages, and who made them.
- **Your own private strings,** such as a private email address or your Mac's name, can go in `.git/info/private-patterns`, one per line. That file never leaves your Mac. The scan matches them as written and also with case, punctuation and line breaks ignored, and reports any match by place only, never by content.
- **CI runs the same scan on GitHub** on every push and pull request, checks each pull request's title and description, and scans the whole history every day. A push made with the hooks skipped is still caught, but by then it's on GitHub, so please don't skip them.
- **A `core.hooksPath` set in your global git config** makes git skip `.git/hooks`. `setup.sh` refuses to finish while one is set.

If the scan flags something, remove it if it's personal or secret. A token that reached a commit should be revoked as well: assume it's leaked. Neither `gitleaks:allow` comments nor `.gitleaksignore` files are honored, since either could wave anything through. For a genuine false positive, say so in your pull request, and a maintainer can add a narrow exception to `.gitleaks.toml` or `scripts/scan.sh`.

Nothing scans comments or issues. Please don't paste logs, crash reports or screenshots there that show your username, your Mac's name or other personal details; trim them first.

## Pull requests
1. Create a branch from `main`.
2. Keep each pull request to one change. Say what it changes and why, and add a screenshot or a short recording for anything visible.
3. CI has to pass: a build with unit tests on macOS, and the secrets scan.
4. Add user-facing changes to `CHANGELOG.md` under "Unreleased", in one sentence about what a user notices.
5. A maintainer reviews it and squash-merges it into `main`.

Commit messages and pull requests are in English, short and specific. A commit's subject says what changed, in the imperative and in about 50 characters ("Fix the timer's ring after sleep"). Add a body only when the subject doesn't explain why, in a few lines. How you tested it belongs in the pull request, not in the commit.

## AI-assisted contributions
Contributions made with AI coding tools are welcome, and you are responsible for every line: understand it and test it on a real Mac.

Jambul doesn't credit AI tools as authors. Commits, pull requests, issues and files carry no co-author trailer for an AI tool and no "generated with" footer, and commits aren't authored as an AI tool. The scan refuses the usual forms of all three. The repository's `.claude/settings.json` already turns that attribution off for Claude Code; with another tool, turn it off yourself or remove it before committing. `CLAUDE.md` holds the instructions for coding agents, and they follow the same rules as everyone else.

## Releases
Maintainers publish releases as described in [docs/RELEASING.md](docs/RELEASING.md).
