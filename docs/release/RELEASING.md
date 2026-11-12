# Releasing Container Desktop

## Every release

```bash
make check                          # green locally
make release VERSION=0.2.0          # bumps Makefile VERSION, promotes CHANGELOG [Unreleased], commits, tags v0.2.0
git push origin main v0.2.0
make publish TAG=v0.2.0             # builds the DMG + .sha256 on this Mac and publishes the GitHub release
```

CI is **manual-only** (both workflows are `workflow_dispatch`): every check runs locally. Install the pre-push
hook once with `make hooks` so `make check` runs before each push.

`scripts/release.sh` refuses to run unless the tree is clean, you are on `main` in sync with `origin/main`
(it fetches tags first), the tag exists neither locally nor on `origin`, and `make check` passes. It verifies the
Makefile and CHANGELOG edits actually landed before committing.

`scripts/publish-release.sh` runs `make check`, builds `Container-Desktop-<version>-arm64.dmg` plus a `.sha256`
(notarizes when `NOTARY_PROFILE` is set), and publishes a GitHub release with the CHANGELOG section, auto-generated
notes and first-launch instructions for unsigned builds. The `Release` workflow still exists for an on-demand
runner build (Actions → Release → Run workflow → tag), but it is never triggered automatically. Tags
containing `-` (e.g. `v0.2.0-beta.1`) are marked pre-release.

## Homebrew cask

Each stable release gets a cask, rendered from `packaging/homebrew/container-desktop.rb.in`:

```bash
make cask VERSION=0.2.0             # → build/container-desktop.rb, from the sha256 of build/Container-Desktop-0.2.0-arm64.dmg
```

`make publish` does this for you after the release is out. The checksum in the cask must be the one of the
**published** DMG, so never run `make dmg` again between publishing and `make cask` (a rebuilt DMG has a different
checksum; `scripts/make-cask.sh` refuses when the DMG and its `.sha256` disagree). To render the cask on another
Mac, pass the published checksum instead: `SHA256=<value from the release's .sha256 asset> make cask VERSION=0.2.0`.

To get the cask into the tap, point `HOMEBREW_TAP_DIR` at a local clone of it before publishing:

```bash
export HOMEBREW_TAP_DIR=~/src/homebrew-tap      # a clone of AIFlow-Labs-Limited/homebrew-tap
make publish TAG=v0.2.0
```

The script copies the cask to `$HOMEBREW_TAP_DIR/Casks/container-desktop.rb` and prints the three git commands
(`add`, `commit`, `push`) for you to run after a look at the diff. It never commits, pushes or creates a
repository. Without `HOMEBREW_TAP_DIR` the cask stays in `build/`. Pre-releases and `--draft` releases are skipped:
the tap only carries stable versions.

After committing and before pushing, check the cask (Homebrew only audits casks that live in a tap, and
`brew tap` clones, so it sees committed changes only):

```bash
brew tap AIFlow-Labs-Limited/tap "$HOMEBREW_TAP_DIR"     # once per machine; afterwards: brew update
brew style --cask AIFlow-Labs-Limited/tap/container-desktop
brew audit --cask --online AIFlow-Labs-Limited/tap/container-desktop
```

Things the cask states that must stay true: the asset name `Container-Desktop-<version>-arm64.dmg`, the bundle
identifier `io.aiflowlabs.containerdesktop` (`uninstall quit:` and the preferences file in `zap`), the history
folder `~/Library/Application Support/Container Desktop` (`BuildsStore.defaultHistoryURL`), and the first-launch
steps in `caveats`, which mirror the README. The minimum runtime version in the caveats is read from
`Sources/AppCore/RuntimeSupport.swift`. Because builds are not notarized, the cask's `postflight` removes the
quarantine flag after Homebrew has checked the sha256. Once builds are notarized, delete that `postflight` block and
the "not notarized" half of the caveats from the template.

The one-line installer (`scripts/install.sh`, linked from the README) needs no per-release step: it follows
`releases/latest` and reads the `.sha256` asset, so it keeps working as long as both assets are attached to
every release. It is fetched from the `main` branch, so a change to it is live for users as soon as it is pushed.

## Supported runtime versions

`Sources/AppCore/RuntimeSupport.swift` is the one place that says which `container` versions the app supports
(`minimum`, `testedUpTo`). When a new runtime release has been tested, raise `testedUpTo` there; the Updates
pane, the status bar notice, the install screen and the cask caveats follow.

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

3. **Signing locally** — export `SIGN_IDENTITY="Developer ID Application: …"` and `NOTARY_PROFILE=container-desktop-notary`
   in the shell that runs `make publish`; builds without them are ad-hoc signed and users need the steps in [Opening an unsigned build](#opening-an-unsigned-ad-hoc-build).
4. **GitHub settings** — protect `main` (one review; no required status check since CI is manual), and enable
   Dependabot alerts (Dependabot PRs do not run CI; run `make check` locally before merging them).
5. **Homebrew tap** (by hand, once; no script does this) — create the **public** repository
   `AIFlow-Labs-Limited/homebrew-tap` on GitHub with a `Casks/` folder. The `homebrew-` prefix is what lets
   users write the short name:

   ```bash
   brew install --cask AIFlow-Labs-Limited/tap/container-desktop
   ```

   Clone it, export `HOMEBREW_TAP_DIR=<path to the clone>` in the shell that runs `make publish`, and push the
   first cask as described in [Homebrew cask](#homebrew-cask). Until the repository exists and holds a cask, the
   Homebrew lines in the README do not work, so merge them only after the first cask is pushed.
