# Releasing Container Desktop

## Every release

```bash
make check                          # green locally
make release VERSION=0.2.0          # bumps Makefile VERSION, promotes CHANGELOG [Unreleased], commits, tags v0.2.0
git push origin main v0.2.0         # the tag triggers .github/workflows/release.yml
```

`scripts/release.sh` refuses to run unless the tree is clean, you are on `main` in sync with `origin/main`
(it fetches tags first), the tag exists neither locally nor on `origin`, and `make check` passes. It verifies the
Makefile and CHANGELOG edits actually landed before committing.

The release workflow runs the tests, builds `Container-Desktop-<version>-arm64.dmg` plus a `.sha256`, and
publishes a GitHub release with auto-generated notes and first-launch instructions for unsigned builds. Tags
containing `-` (e.g. `v0.2.0-beta.1`) are marked pre-release.

The Homebrew tap is not published yet (README says "Homebrew tap coming — for now use the DMG"). Once it exists,
update the cask (`packaging/homebrew/container-desktop.rb` → tap repo) with the new `version` and the `sha256`
from the release asset.

## Opening an unsigned (ad-hoc) build

Until CI signs and notarizes, users see a Gatekeeper block on first launch. Right-click → Open no longer bypasses
it on recent macOS, and a quarantined ad-hoc app may be reported as "damaged". Give users these two options (the
release notes and README carry the same text):

1. Open the app once, then **System Settings → Privacy & Security** → **Open Anyway** next to the message about
   *Container Desktop*.
2. Or: `xattr -dr com.apple.quarantine "/Applications/Container Desktop.app"`

## Signed + notarized builds (local)

```bash
export SIGN_IDENTITY="Developer ID Application: AIFLOW LABS LIMITED (TEAMID)"
export NOTARY_PROFILE=container-desktop-notary
make app dmg notarize
```

`make notarize` is a no-op with a message when `NOTARY_PROFILE` is unset, and refuses unsigned, ad-hoc signed or
non-Developer-ID artifacts. `scripts/bundle.sh` signs nested code (if any) inside-out and then the app, without
the deprecated `--deep`.

## One-time setup

1. **Developer ID certificate** — in the Apple Developer account, create a *Developer ID Application*
   certificate and install it in the login keychain (`security find-identity -v -p codesigning` lists it).
2. **Notary credentials** — create an app-specific password at appleid.apple.com, then:

   ```bash
   xcrun notarytool store-credentials container-desktop-notary \
       --apple-id "<apple-id>" --team-id "<TEAMID>" --password "<app-specific-password>"
   ```

3. **CI signing (optional, later)** — to sign/notarize in GitHub Actions, add repository secrets for the
   exported `.p12` certificate + password and an App Store Connect API key, import them into a temporary keychain
   in `release.yml`, and set `SIGN_IDENTITY` / `NOTARY_PROFILE`. Until then CI releases are ad-hoc signed, and
   users need the steps in [Opening an unsigned build](#opening-an-unsigned-ad-hoc-build).
4. **GitHub settings** — protect `main` (require the `CI / Build, test, bundle` check and one review), allow
   GitHub Actions to create releases (Settings → Actions → Workflow permissions: read and write), and enable
   Dependabot alerts.
5. **Homebrew** — create the tap repo `AIFlow-Labs-Limited/homebrew-tap` with `Casks/container-desktop.rb`
   (until accepted into homebrew/cask: `brew install --cask aiflow-labs-limited/tap/container-desktop`).
