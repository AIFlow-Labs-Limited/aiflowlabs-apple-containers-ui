# Releasing Container Desktop

## Every release

```bash
make check                          # green locally
make release VERSION=0.2.0          # bumps Makefile VERSION, promotes CHANGELOG [Unreleased], commits, tags v0.2.0
git push origin main v0.2.0         # the tag triggers .github/workflows/release.yml
```

The release workflow runs the tests, builds `Container-Desktop-<version>-arm64.dmg` plus a `.sha256`, and
publishes a GitHub release with auto-generated notes. Tags containing `-` (e.g. `v0.2.0-beta.1`) are marked
pre-release.

Then update the Homebrew cask (`packaging/homebrew/container-desktop.rb` → tap repo) with the new `version` and
the `sha256` from the release asset.

## Signed + notarized builds (local)

```bash
export SIGN_IDENTITY="Developer ID Application: AIFLOW LABS LIMITED (TEAMID)"
export NOTARY_PROFILE=container-desktop-notary
make app dmg notarize
```

`make notarize` is a no-op with a message when `NOTARY_PROFILE` is unset, and refuses ad-hoc signed artifacts.

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
   users must right-click → Open on first launch.
4. **GitHub settings** — protect `main` (require the `CI / Build, test, bundle` check and one review), allow
   GitHub Actions to create releases (Settings → Actions → Workflow permissions: read and write), and enable
   Dependabot alerts.
5. **Homebrew** — create the tap repo `AIFlow-Labs-Limited/homebrew-tap` with `Casks/container-desktop.rb`
   (until accepted into homebrew/cask: `brew install --cask aiflow-labs-limited/tap/container-desktop`).
