# Homebrew cask draft for Container Desktop.
# Publish to a tap (e.g. AIFlow-Labs-Limited/homebrew-tap → Casks/container-desktop.rb) once a notarized
# DMG is on GitHub Releases. Update `version` and `sha256` from the release's .sha256 asset each release.
cask "container-desktop" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui/releases/download/v#{version}/Container-Desktop-#{version}-arm64.dmg"
  name "Container Desktop"
  desc "Native dashboard for Apple's container runtime"
  homepage "https://github.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "Container Desktop.app"

  caveats <<~EOS
    Container Desktop drives Apple's `container` CLI (1.5 or later), which is installed separately:
      https://github.com/apple/container/releases
  EOS

  zap trash: [
    "~/Library/Application Support/Container Desktop",
    "~/Library/Caches/io.aiflowlabs.containerdesktop",
    "~/Library/HTTPStorages/io.aiflowlabs.containerdesktop",
    "~/Library/Preferences/io.aiflowlabs.containerdesktop.plist",
    "~/Library/Saved Application State/io.aiflowlabs.containerdesktop.savedState",
  ]
end
