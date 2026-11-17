#!/bin/bash
# Build "QX20 Print.app" into macos/build/.
#   ./build-app.sh             build for this Mac
#   ./build-app.sh --release   universal (Apple Silicon + Intel) + zip for GitHub Releases
#   ./build-app.sh --install   build, copy to /Applications (needed for the Location
#                              permission: macOS can't verify apps inside your home folder)
#                              and link the `qx20` command line tool into your PATH
set -euo pipefail
cd "$(dirname "$0")"

RELEASE=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --release) RELEASE=1 ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ $RELEASE = 1 ]; then
  ARCHS=(--arch arm64 --arch x86_64)
else
  ARCHS=()
fi
swift build -c release --product QX20Print ${ARCHS[@]+"${ARCHS[@]}"}
swift build -c release --product qx20 ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

APP="build/QX20 Print.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/QX20Print" "$APP/Contents/MacOS/QX20Print"
# Command line tool, inside the bundle so macOS can verify it (Location permission)
cp "$BIN/qx20" "$APP/Contents/MacOS/qx20"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null
fi

# No Finder/quarantine metadata in the bundle (avoids "._" files in the zip)
xattr -cr "$APP"

# Ad-hoc signature: required so macOS can grant the Location permission.
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/qx20"
codesign --force --sign - --timestamp=none "$APP"
echo "App: $(pwd)/$APP ($(lipo -archs "$APP/Contents/MacOS/QX20Print"))"

if [ $RELEASE = 1 ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
  ZIP="build/QX20-Print-$VERSION-macOS.zip"
  rm -f "$ZIP"
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
  echo "Zip: $(pwd)/$ZIP"
  shasum -a 256 "$ZIP"
fi

if [ $INSTALL = 1 ]; then
  DEST="/Applications/QX20 Print.app"
  osascript -e 'tell application "QX20 Print" to quit' >/dev/null 2>&1 || true
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "Installed: $DEST"

  # `qx20` on the PATH (a link to the binary inside the app)
  if [ -w /usr/local/bin ]; then BINDIR=/usr/local/bin; else BINDIR="$HOME/.local/bin"; mkdir -p "$BINDIR"; fi
  ln -sf "$DEST/Contents/MacOS/qx20" "$BINDIR/qx20"
  echo "CLI: $BINDIR/qx20"
  case ":$PATH:" in *":$BINDIR:"*) ;; *) echo "  (add $BINDIR to your PATH to use 'qx20')" ;; esac
fi
