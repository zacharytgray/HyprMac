cask "hyprmac" do
  version "0.27.0"
  sha256 "418ab61fd7a001586ae662d246d962c7eab91952e5bd7d9227eccb4d36a42931"

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
