cask "hyprmac" do
  version "0.8.0"
  sha256 "ba3b70ad8adee09b622ae575e782a25083c9f0af68aa128141a0274e6445ff66"

  url "https://github.com/zacharytgray/HyprMac/releases/download/v#{version}/HyprMac-#{version}.dmg"
  name "HyprMac"
  desc "Tiling window manager for macOS inspired by Hyprland"
  homepage "https://github.com/zacharytgray/HyprMac"

  depends_on macos: ">= :ventura"

  app "HyprMac.app"

  postflight do
    # remind user about accessibility permission
    ohai "HyprMac requires Accessibility permission."
    ohai "Grant it in System Settings → Privacy & Security → Accessibility"
  end

  zap trash: [
    "~/Library/Application Support/HyprMac",
  ]
end
