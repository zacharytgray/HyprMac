cask "hyprmac" do
  version "0.27.1"
  sha256 "ea067f2fc52696c94d17cb86bcfa3febcaec5053bba67829a9550c5fae53c257"

  url "https://github.com/zacharytgray/HyprMac/releases/download/v#{version}/HyprMac.dmg"
  name "HyprMac"
  desc "Tiling window manager for macOS inspired by Hyprland"
  homepage "https://hyprmac.app"

  auto_updates true
  depends_on macos: :ventura

  app "HyprMac.app"

  zap trash: [
    "~/Library/Application Support/HyprMac",
  ]

  caveats <<~EOS
    HyprMac requires Accessibility permission.
    Grant it in System Settings → Privacy & Security → Accessibility.
  EOS
end
