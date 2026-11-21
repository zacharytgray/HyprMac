cask "hyprmac" do
  version "0.26.0"
  sha256 "0463cd814941a4c192198e8481b814e1e07b999c8672df2579ab0429c8ce542e"

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
