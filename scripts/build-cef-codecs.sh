#!/bin/bash
# Build the CEF framework NotArc ships with H.264 and AAC (proprietary codecs), from source.
#
# Spotify's prebuilt CEF ("cef-builds.spotifycdn.com") leaves out H.264/AAC, so MP4 video and the MSE streams used by
# X, Instagram, Facebook and many news sites fail ("The media could not be played"). Chromium's own switches
# `proprietary_codecs=true ffmpeg_branding=Chrome` turn them on; there is no runtime switch.
#
# Usage: scripts/build-cef-codecs.sh <work dir, no spaces> [step]
#   steps (default: all, in order): sync, framework, assemble
# Needs ~110 GB free, a few hours on an M-series Mac, and the Command Line Tools. Full Xcode isn't needed: without it
# the script makes a stand-in developer folder that points Chromium's build at the Command Line Tools SDK, and ANGLE
# compiles its Metal shaders at runtime instead of at build time.
# Result: third_party/std/<CEF folder>_codecs, a copy of the standard distribution with the codec framework in
# Release/. Link it with `ln -sfn std/<that folder> third_party/cef` and rebuild NotArc.
#
# Licensing: H.264 and AAC are patent-licensed codecs. Building for yourself is fine; distributing a build with them
# may need a licence (MPEG LA / Via LA) depending on how many copies you ship.
set -euo pipefail

CEF_VERSION="156.0.7+g47dbc1d+chromium-156.0.8078.17"
CEF_COMMIT="47dbc1df023e99f006fb9e850a8d83cc19b4fdd9"
CHROMIUM_BRANCH="8078"
STD_NAME="cef_binary_${CEF_VERSION}_macosarm64"

WORK="${1:?usage: build-cef-codecs.sh <work dir> [sync|framework|assemble]}"
STEP="${2:-all}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
case "$WORK" in *" "*) echo "work dir must not contain spaces (Chromium's build breaks)"; exit 2 ;; esac
mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"
DL="$WORK/download"; SRC="$DL/chromium/src"; OUT="$SRC/out/Release_GN_arm64"

export PATH="$WORK/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0
export GN_DEFINES="is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome symbol_level=0 treat_warnings_as_errors=false"

# Chromium's build asks Xcode for SDK paths and versions. With only the Command Line Tools, answer from a stand-in.
if ! xcodebuild -version >/dev/null 2>&1; then
  FX="$WORK/FakeXcode.app/Contents"; D="$FX/Developer"
  SDKV="$(xcrun --sdk macosx --show-sdk-version)"; SDKB="$(xcrun --sdk macosx --show-sdk-build-version)"
  CLT=/Library/Developer/CommandLineTools
  mkdir -p "$D/Platforms/MacOSX.platform/Developer/SDKs" "$D/Toolchains/XcodeDefault.xctoolchain" "$D/usr/bin"
  ln -sfn "$CLT/SDKs/MacOSX${SDKV}.sdk" "$D/Platforms/MacOSX.platform/Developer/SDKs/MacOSX${SDKV}.sdk"
  ln -sfn "MacOSX${SDKV}.sdk" "$D/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
  ln -sfn "$CLT/usr" "$D/Toolchains/XcodeDefault.xctoolchain/usr"
  for f in "$CLT"/usr/bin/*; do [ "$(basename "$f")" = xcodebuild ] || ln -sfn "$f" "$D/usr/bin/$(basename "$f")"; done
  for d in lib libexec share include; do ln -sfn "$CLT/usr/$d" "$D/usr/$d"; done
  plist() { printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>%s</dict></plist>\n' "$1"; }
  plist "<key>CFBundleShortVersionString</key><string>${SDKV}</string><key>ProductBuildVersion</key><string>CLT</string>" > "$FX/version.plist"
  cp "$FX/version.plist" "$FX/Info.plist"
  plist "<key>CFBundleIdentifier</key><string>com.apple.platform.macosx</string><key>Name</key><string>macosx</string><key>Version</key><string>${SDKV}</string>" \
    > "$D/Platforms/MacOSX.platform/Info.plist"
  cat > "$D/usr/bin/xcodebuild" <<EOF
#!/bin/bash
# Stand-in for xcodebuild (Command Line Tools only): answers version, path and tool lookups. Builds nothing.
D="$D"; tool=""; ver=0; key=""; a=("\$@")
for ((i = 0; i < \${#a[@]}; i++)); do
  case "\${a[\$i]}" in
    -license|-checkFirstLaunchStatus|-runFirstLaunch) exit 0 ;;
    -sdk) i=\$((i + 1)) ;;
    -find) i=\$((i + 1)); tool="\${a[\$i]}" ;;
    -version) ver=1; key="\${a[\$((i + 1))]:-}"; i=\$((i + 1)) ;;
  esac
done
if [ -n "\$tool" ]; then
  for dir in "\$D/Toolchains/XcodeDefault.xctoolchain/usr/bin" "\$D/usr/bin" /usr/bin /bin; do
    [ -x "\$dir/\$tool" ] && { echo "\$dir/\$tool"; exit 0; }
  done
  exit 1
fi
if [ "\$ver" = 1 ]; then
  case "\$key" in
    "") printf 'Xcode ${SDKV}\nBuild version CLT\n' ;;
    PlatformPath) echo "\$D/Platforms/MacOSX.platform" ;;
    Path) echo "\$D/Platforms/MacOSX.platform/Developer/SDKs/MacOSX${SDKV}.sdk" ;;
    SDKVersion|ProductVersion|PlatformVersion) echo ${SDKV} ;;
    ProductBuildVersion) echo ${SDKB} ;;
    *) exit 1 ;;
  esac
  exit 0
fi
echo "stand-in xcodebuild: unsupported: \$*" >&2; exit 1
EOF
  chmod +x "$D/usr/bin/xcodebuild"
  export DEVELOPER_DIR="$D"
  NO_METAL=1
fi

sync() {
  [ -d "$WORK/depot_tools" ] || git clone -q https://chromium.googlesource.com/chromium/tools/depot_tools.git "$WORK/depot_tools"
  (cd "$WORK/depot_tools" && bash -c 'source ./bootstrap_python3 && bootstrap_python3')
  curl -sfo "$WORK/automate-git.py" \
    "https://raw.githubusercontent.com/chromiumembedded/cef/$CEF_COMMIT/tools/automate/automate-git.py"
  # One go: with --no-chromium-history, automate-git only syncs Chromium's dependencies and runs hooks the first time.
  # If this stops halfway, run `gclient sync --nohooks --no-history && gclient runhooks` in $DL/chromium.
  python3 "$WORK/automate-git.py" --download-dir="$DL" --depot-tools-dir="$WORK/depot_tools" --branch="$CHROMIUM_BRANCH" \
    --checkout="$CEF_COMMIT" --arm64-build --no-debug-build --no-chromium-history --with-pgo-profiles --no-build --no-distrib
}

framework() {
  cd "$SRC"
  if [ "${NO_METAL:-}" = 1 ]; then  # no Metal compiler: ANGLE falls back to compiling its shaders at runtime
    G=third_party/angle/src/libANGLE/renderer/metal/metal_backend.gni
    grep -q "NOTARC: no metal tool" "$G" || sed -i '' \
      's/^metal_internal_shader_compilation_supported =$/metal_internal_shader_compilation_supported = false \&\& # NOTARC: no metal tool/' "$G"
  fi
  (cd cef && python3 tools/gclient_hook.py)  # applies CEF's patches and runs gn gen with GN_DEFINES
  # Only the framework: CEF's sample apps need ibtool (Xcode) and NotArc doesn't use them.
  autoninja -C "$OUT" cef_framework
}

assemble() {
  # Same CEF commit = same headers, wrapper and CMake files as the standard distribution: reuse those and swap in the
  # framework built here.
  STD="$REPO/third_party/std/$STD_NAME"
  if [ ! -d "$STD" ]; then
    mkdir -p "$REPO/third_party/std"
    curl -fL "https://cef-builds.spotifycdn.com/${STD_NAME}.tar.bz2" | tar -xj -C "$REPO/third_party/std"
  fi
  DEST="$REPO/third_party/std/${STD_NAME}_codecs"
  rm -rf "$DEST"; ditto "$STD" "$DEST"
  rm -rf "$DEST/Release/Chromium Embedded Framework.framework" "$DEST/Debug"
  ditto "$OUT/Chromium Embedded Framework.framework" "$DEST/Release/Chromium Embedded Framework.framework"
  printf 'Built from source by scripts/build-cef-codecs.sh on %s with GN_DEFINES="%s"\n' "$(date -u +%F)" "$GN_DEFINES" \
    > "$DEST/CODECS.txt"
  echo "Done: $DEST"
  echo "Link it: ln -sfn std/${STD_NAME}_codecs \"$REPO/third_party/cef\", then rebuild NotArc."
}

case "$STEP" in
  all) sync; framework; assemble ;;
  sync|framework|assemble) "$STEP" ;;
  *) echo "unknown step $STEP"; exit 2 ;;
esac
