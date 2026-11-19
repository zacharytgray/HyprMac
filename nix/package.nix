{
  lib,
  stdenvNoCC,
  fetchurl,
  _7zz,
  caskFile ? ../Casks/hyprmac.rb,
  version ? null,
  sha256 ? null,
}:
let
  caskText = builtins.readFile caskFile;

  extractField =
    field: pattern:
    let
      matched = builtins.match ".*${field}[[:space:]]+\"(${pattern})\".*" caskText;
    in
    if matched == null then
      throw "nix/package.nix: failed to parse '${field}' from ${toString caskFile}"
    else
      builtins.head matched;

  resolvedVersion =
    if version != null then version else extractField "version" "[0-9A-Za-z._+-]+";

  resolvedSha256 =
    if sha256 != null then sha256 else extractField "sha256" "[0-9a-f]{64}";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "hyprmac";
  version = resolvedVersion;

  strictDeps = true;
  __structuredAttrs = true;

  src = fetchurl {
    url = "https://github.com/zacharytgray/HyprMac/releases/download/v${finalAttrs.version}/HyprMac.dmg";
    sha256 = resolvedSha256;
  };

  # hdiutil on modern macOS formats UDZO DMGs with APFS by default, which undmg
  # does not support. _7zz extracts APFS DMGs cleanly while preserving bundle
  # symlinks and the Developer ID signature.
  nativeBuildInputs = [ _7zz ];

  sourceRoot = "HyprMac.app";

  dontPatch = true;
  dontConfigure = true;
  dontBuild = true;
  # Keep the upstream Developer ID signature and notarization seal intact so
  # macOS Accessibility (TCC) trust persists across updates.
  dontFixup = true;
  dontPatchShebangs = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    appDir="$out/Applications/HyprMac.app"
    mkdir -p "$appDir"
    cp -PR . "$appDir"

    runHook postInstall
  '';

  doInstallCheck = true;

  installCheckPhase = ''
    runHook preInstallCheck

    appDir="$out/Applications/HyprMac.app"
    test -x "$appDir/Contents/MacOS/HyprMac"
    test -f "$appDir/Contents/Info.plist"

    if [[ -x /usr/bin/codesign ]]; then
      /usr/bin/codesign --verify --deep --strict "$appDir"
    fi

    runHook postInstallCheck
  '';

  meta = {
    description = "Tiling window manager for macOS inspired by Hyprland";
    homepage = "https://github.com/zacharytgray/HyprMac";
    changelog = "https://github.com/zacharytgray/HyprMac/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
