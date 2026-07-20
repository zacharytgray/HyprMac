cask "hyprmac" do
  version "0.10.1"
  sha256 "6c7d81a40509e8fbc33fbf32b34c4fd0851c224518f84ed931aa4d81dbc514d0"

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
