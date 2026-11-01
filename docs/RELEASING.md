# Releasing Jambul

Releases are built and published by the [Release workflow](../.github/workflows/release.yml) when a version tag is pushed. Versions follow [Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`, still below 1.0 while Jambul settles.

## Steps
1. **Prepare the release in a pull request:**
   - In `CHANGELOG.md`, rename "Unreleased" to the new version and date, such as `## [0.2.0] - 2026-12-01`, and start a new empty "Unreleased" section above it.
   - In `project.yml`, set `MARKETING_VERSION` to the new version and raise `CURRENT_PROJECT_VERSION` by one. Then run `xcodegen generate`.
   - Run `./scripts/test.sh`, then merge the pull request once CI passes.
2. **Tag the merged commit on `main`:**
   ```sh
   git switch main && git pull
   git tag -a v0.2.0 -m "Jambul 0.2.0"
   git push origin v0.2.0
   ```
   The pre-push hook scans the tag too, so its message and its tagger, your `user.email`, must hold nothing private.
3. **The workflow** first runs the same scan as CI over every commit and tag, and publishes nothing if it finds anything. It then builds the Release configuration on a macOS runner and checks that both the tag and the built app match `MARKETING_VERSION`. Finally it zips `Jambul.app`, writes a SHA-256 checksum, and publishes a GitHub release with that version's notes from `CHANGELOG.md`.
4. **Check the release:** download the zip on a Mac, verify it with `shasum -a 256 -c Jambul-<version>.zip.sha256`, and open it as the README describes.

## Signing
Releases are ad-hoc signed and not notarized, because Jambul doesn't have an Apple Developer ID yet. That's why macOS asks people to choose **Open Anyway** the first time.

Notarization and automatic updates with Sparkle are planned for later. When they come, the signing certificate, its password and the notarization credentials will live only in GitHub Actions secrets for the Release workflow, never in the repository or in a log.
