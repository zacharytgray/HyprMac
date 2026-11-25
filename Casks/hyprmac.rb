cask "hyprmac" do
  version "0.29.0"
  sha256 "7e11cc0d0e71dd44cf37288577a9cccd1f36e3c5d7ba4cb4e3aa45d361ef5021"

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
