cask "hyprmac" do
  version "0.3.1"
  sha256 "6b15f35c23e4ec125f877a5b9925cebc60c0d46ac5a401d4a1d77d4db4cfbab0"

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
