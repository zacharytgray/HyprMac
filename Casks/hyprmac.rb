cask "hyprmac" do
  version "0.2.2"
  sha256 "a26d1f4aa613ade790d82306cd168ad4a42920b7bda71588bd34c34e6077ce36"

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
