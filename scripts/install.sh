#!/usr/bin/env bash
# Install Container Desktop without Homebrew.
#
#   curl -fsSL https://raw.githubusercontent.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui/main/scripts/install.sh | bash
#   curl -fsSL …/scripts/install.sh | bash -s -- --yes        # replace an existing copy without asking
#   scripts/install.sh --dry-run                               # show what would happen, change nothing
#
# What it does: finds the latest release on GitHub, downloads the DMG and its .sha256, verifies the checksum
# (aborts on mismatch), mounts the DMG read-only, copies "Container Desktop.app" to /Applications, unmounts and
# removes its temporary files on every exit path. It never uses sudo and installs nothing else.
#
# The checksum is published next to the DMG, so it catches a corrupted or truncated download, not a compromised
# release. Builds are ad-hoc signed and not notarized yet; see the note printed at the end.
#
# Everything lives in functions and `main` is called on the last line, so a download of this script that is cut
# short runs nothing.
set -euo pipefail

REPO="AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui"
APP_NAME="Container Desktop"
PROCESS_NAME="ContainerDesktop"
MIN_MACOS_MAJOR=26

ASSUME_YES=0
DRY_RUN=0
VERSION=""
DEST_DIR="/Applications"

WORK_DIR=""
MOUNT_POINT=""
STAGED=""

say() { printf '%s\n' "$*"; }
step() { printf '==> %s\n' "$*"; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Install Container Desktop (the native dashboard for Apple's container runtime).

Usage: install.sh [options]
  --yes            Replace an existing copy without asking.
  --dry-run        Print what would be done; download and change nothing.
  --version X.Y.Z  Install this release instead of the latest.
  --dir DIR        Install into DIR instead of /Applications (for example ~/Applications).
  -h, --help       Show this help.

Requires macOS $MIN_MACOS_MAJOR or later on Apple silicon.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes | -y) ASSUME_YES=1 ;;
            --dry-run | -n) DRY_RUN=1 ;;
            --version)
                [[ $# -ge 2 ]] || die "--version needs a value (for example --version 0.2.0)"
                VERSION="${2#v}"
                shift
                ;;
            --dir)
                [[ $# -ge 2 ]] || die "--dir needs a directory"
                DEST_DIR="$2"
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "unknown option: $1"
                ;;
        esac
        shift
    done
}

# Removes everything this run created. Runs on every exit path (success, error, Ctrl-C).
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$MOUNT_POINT" ]] && [[ -d "$MOUNT_POINT" ]]; then
        hdiutil detach "$MOUNT_POINT" -quiet 2> /dev/null || hdiutil detach "$MOUNT_POINT" -force -quiet 2> /dev/null || true
    fi
    if [[ -n "$STAGED" ]] && [[ -e "$STAGED" ]]; then
        rm -rf "$STAGED"
    fi
    if [[ -n "$WORK_DIR" ]] && [[ -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
    exit "$status"
}

# True for "0.2.0"; pre-release and other shapes are refused.
is_release_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

check_platform() {
    [[ "$(uname -s)" == "Darwin" ]] || die "Container Desktop runs on macOS only (this is $(uname -s))."
    # hw.optional.arm64 stays 1 under Rosetta, where `uname -m` would claim x86_64.
    [[ "$(sysctl -n hw.optional.arm64 2> /dev/null || echo 0)" == "1" ]] \
        || die "Container Desktop needs a Mac with Apple silicon; this Mac has an Intel processor."
    local product major
    product="$(sw_vers -productVersion)"
    major="${product%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] || die "could not read the macOS version (got '$product')."
    [[ "$major" -ge "$MIN_MACOS_MAJOR" ]] \
        || die "Container Desktop needs macOS $MIN_MACOS_MAJOR or later; this Mac runs macOS $product."
}

fetch() { curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$@"; }

# The latest release's version, read from where github.com/<repo>/releases/latest redirects to
# (…/releases/tag/vX.Y.Z). No API call, so no rate limit and no JSON parsing.
latest_version() {
    local effective tag
    effective="$(fetch --head --output /dev/null --write-out '%{url_effective}' "https://github.com/$REPO/releases/latest")" \
        || die "could not reach github.com to find the latest release."
    tag="${effective##*/}"
    is_release_version "${tag#v}" || die "could not work out the latest release (GitHub sent us to $effective)."
    printf '%s\n' "${tag#v}"
}

# verify_checksum FILE SHA256_FILE: the first field of SHA256_FILE must be FILE's SHA-256.
verify_checksum() {
    local file="$1" sums="$2" expected actual
    expected="$(awk 'NR == 1 { print $1 }' "$sums")"
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "the published checksum file is not a SHA-256 checksum."
    expected="$(printf '%s' "$expected" | tr 'A-F' 'a-f')"
    actual="$(shasum -a 256 "$file" | awk '{ print $1 }')"
    if [[ "$expected" != "$actual" ]]; then
        printf 'error: checksum mismatch. Nothing was installed.\n  expected %s\n  actual   %s\n' \
            "$expected" "$actual" >&2
        exit 1
    fi
}

# confirm PROMPT: asks on the terminal even when the script itself arrives on stdin (curl … | bash).
confirm() {
    local reply=""
    [[ "$ASSUME_YES" -eq 1 ]] && return 0
    if ! (: < /dev/tty) 2> /dev/null; then
        die "$1 Cannot ask without a terminal; run again with --yes to replace it."
    fi
    printf '%s [y/N] ' "$1" > /dev/tty
    IFS= read -r reply < /dev/tty || reply=""
    [[ "$reply" == "y" || "$reply" == "Y" || "$reply" == "yes" ]]
}

app_is_running() { pgrep -x "$PROCESS_NAME" > /dev/null 2>&1; }

print_next_steps() {
    local dest="$1"
    cat <<EOF

Installed: $dest

First launch
  This build is ad-hoc signed and not notarized yet. Because it was downloaded with curl, macOS normally
  opens it without a warning. If macOS blocks it anyway, either open System Settings → Privacy & Security
  and click "Open Anyway" next to the message about Container Desktop, or run once:
    xattr -dr com.apple.quarantine "$dest"

EOF
    if [[ -x /usr/local/bin/container || -x /opt/homebrew/bin/container ]]; then
        say "Apple's container runtime is installed. Open Container Desktop and press Start."
    else
        cat <<EOF
Apple's container runtime is not installed yet (Container Desktop is a dashboard for it). Install it from
  https://github.com/apple/container/releases/latest
or with Homebrew:
  brew install container
Then open Container Desktop and press Start.
EOF
    fi
}

main() {
    parse_args "$@"
    check_platform

    if [[ -n "$VERSION" ]]; then
        is_release_version "$VERSION" || die "'$VERSION' is not a release version (expected X.Y.Z)."
    else
        step "Finding the latest release"
        VERSION="$(latest_version)"
    fi

    local dmg_name="${APP_NAME// /-}-${VERSION}-arm64.dmg"
    local base="https://github.com/$REPO/releases/download/v$VERSION"
    local dest="${DEST_DIR%/}/$APP_NAME.app"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        say "Dry run: nothing is downloaded or changed."
        say "  version      $VERSION"
        say "  download     $base/$dmg_name"
        say "  checksum     $base/$dmg_name.sha256"
        say "  install to   $dest"
        if [[ -e "$dest" ]]; then
            if [[ "$ASSUME_YES" -eq 1 ]]; then
                say "  existing     would be replaced (--yes)"
            else
                say "  existing     found; would ask before replacing it"
            fi
            if app_is_running; then say "  running      Container Desktop is open; the install would stop and ask you to quit it"; fi
        else
            say "  existing     none"
        fi
        if [[ ! -d "$DEST_DIR" || ! -w "$DEST_DIR" ]]; then say "  warning      $DEST_DIR is missing or not writable; the install would stop"; fi
        return 0
    fi

    [[ -d "$DEST_DIR" ]] || die "$DEST_DIR does not exist."
    [[ -w "$DEST_DIR" ]] || die "$DEST_DIR is not writable by $(id -un). Use --dir ~/Applications, or install the DMG by hand."
    case "$dest" in
        */"$APP_NAME.app") ;;
        *) die "refusing to install to unexpected path '$dest'." ;;
    esac

    if [[ -e "$dest" ]]; then
        if app_is_running; then die "Container Desktop is running. Quit it (your containers keep running), then run this again."; fi
        confirm "$dest already exists. Replace it with version $VERSION?" || die "left the existing copy untouched."
    fi

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/container-desktop-install.XXXXXX")"
    local dmg="$WORK_DIR/$dmg_name"

    step "Downloading $dmg_name"
    fetch --output "$dmg" "$base/$dmg_name" || die "download failed: $base/$dmg_name"
    fetch --output "$dmg.sha256" "$base/$dmg_name.sha256" || die "download failed: $base/$dmg_name.sha256"

    step "Verifying the checksum"
    verify_checksum "$dmg" "$dmg.sha256"

    step "Mounting the disk image"
    local mount="$WORK_DIR/mount"
    mkdir "$mount"
    hdiutil attach "$dmg" -nobrowse -readonly -noautoopen -mountpoint "$mount" -quiet || die "could not mount $dmg_name."
    MOUNT_POINT="$mount"
    local source="$mount/$APP_NAME.app"
    [[ -d "$source" ]] || die "the disk image does not contain $APP_NAME.app."
    codesign --verify --strict "$source" || die "the app's code signature is broken. Nothing was installed."

    step "Copying to $DEST_DIR"
    # Copy next to the destination first, then swap, so a failed copy never leaves a half-written app in place.
    STAGED="${DEST_DIR%/}/.$APP_NAME.app.installing.$$"
    ditto "$source" "$STAGED"
    if [[ -e "$dest" ]]; then rm -rf "$dest"; fi
    mv "$STAGED" "$dest"
    STAGED=""

    step "Unmounting"
    hdiutil detach "$mount" -quiet || hdiutil detach "$mount" -force -quiet || true
    MOUNT_POINT=""

    print_next_steps "$dest"
}

# Run unless the file is being sourced (tests source it to call the functions directly).
(return 0 2> /dev/null) || main "$@"
