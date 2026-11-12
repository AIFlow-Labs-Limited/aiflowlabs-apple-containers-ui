<!--
Draft of the README "Install" section (replaces the current "## Install" up to, but not including,
"### Build from source"). Do not merge the Homebrew parts before the tap repository
AIFlow-Labs-Limited/homebrew-tap exists and holds Casks/container-desktop.rb (docs/release/RELEASING.md).
-->

## Install

**Requirements:** macOS 26 (Tahoe) or later on Apple silicon, and Apple's
[`container`](https://github.com/apple/container) runtime 1.5.0 or later (tested up to 1.7.1). Container Desktop
is a dashboard for that runtime; it does not include it.

### 1. Homebrew (recommended)

```bash
brew install container                                            # Apple's runtime, if you do not have it yet
brew install --cask AIFlow-Labs-Limited/tap/container-desktop
```

### 2. One-line installer

No Homebrew? This downloads the latest release, checks it against its published SHA-256 checksum and copies the
app to `/Applications`. It does not use `sudo`, and it asks before replacing an existing copy.

```bash
curl -fsSL https://raw.githubusercontent.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui/main/scripts/install.sh | bash
```

To see what it would do without changing anything, add `-s -- --dry-run` after `bash`. Other options:
`--yes` (replace without asking), `--version X.Y.Z`, `--dir ~/Applications`. You can
[read the script](scripts/install.sh) first.

### 3. Download the DMG

1. Download `Container-Desktop-<version>-arm64.dmg` from
   [Releases](https://github.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui/releases/latest), open it and
   drag *Container Desktop* to *Applications*.
2. Optional: each release has a `.sha256` file. With both files in the same folder,
   `shasum -a 256 -c Container-Desktop-<version>-arm64.dmg.sha256` should print `OK`.

### First launch

Builds are ad-hoc signed and not notarized yet, so macOS blocks the first launch of a copy installed with
Homebrew or from the DMG (right-click → Open no longer bypasses this, and a quarantined ad-hoc app can be
reported as "damaged"). Either open the app once, then go to **System Settings → Privacy & Security** and click
**Open Anyway**, or remove the quarantine flag:

```bash
xattr -dr com.apple.quarantine "/Applications/Container Desktop.app"
```

A copy installed with the one-line installer normally opens without this step, because `curl` does not mark
downloads as quarantined.

### The runtime

If Apple's runtime is missing, Container Desktop says so on launch and shows the way: install it with
`brew install container` or with the signed installer from
[apple/container releases](https://github.com/apple/container/releases/latest), press **Check Again**, then press
**Start container system** (the app runs `container system start` for you).

### Updating

Container Desktop checks github.com once a day for a newer release of itself and of the runtime and shows a small
"Update available" note in the status bar; details are in **Settings → Updates** (or **Container Desktop → Check
for Updates…**). The check sends nothing about you or your containers, and you can turn it off there. The app
never downloads or installs anything by itself.

| Installed with | Update Container Desktop | Update the runtime |
|---|---|---|
| Homebrew | `brew upgrade --cask container-desktop` | `brew upgrade container` |
| One-line installer | run the installer again (add `-s -- --yes` after `bash` to skip the question) | installer from [apple/container releases](https://github.com/apple/container/releases/latest) |
| DMG | download the new DMG and replace the app in *Applications* | installer from [apple/container releases](https://github.com/apple/container/releases/latest) |

Quit Container Desktop before replacing it; your containers keep running. Upgrading the **runtime** is different:
running containers stop, so stop what matters first and start the container system again afterwards. Homebrew's
`container` formula can be a few days behind Apple's release.

### Uninstalling

| Installed with | Remove the app | Also remove its settings and build history |
|---|---|---|
| Homebrew | `brew uninstall --cask container-desktop` | `brew uninstall --zap --cask container-desktop` |
| Installer or DMG | quit the app, then move *Container Desktop* from *Applications* to the Trash | see below |

Container Desktop keeps two things outside the app, both small:

```bash
rm -rf ~/Library/Application\ Support/Container\ Desktop                 # build history
rm -f ~/Library/Preferences/io.aiflowlabs.containerdesktop.plist         # settings
```

Removing Container Desktop does not touch your containers, images or volumes: they belong to Apple's runtime.
To remove the runtime as well, follow [apple/container](https://github.com/apple/container)'s instructions (or
`brew uninstall container` if you installed it with Homebrew).
