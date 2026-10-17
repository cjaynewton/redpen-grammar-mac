#!/bin/zsh
# Builds Redpen.app and installs it to ~/Applications.
#
# Optional, in a .local.env file next to this script (not committed):
#   REDPEN_SIGN_ID="Apple Development"   # sign with your certificate so Accessibility survives rebuilds
#   REDPEN_BUNDLE_ID="com.example.redpen"
set -e
cd "${0:A:h}"
# A signing identity passed in (release.sh passes the Developer ID) wins over the one in .local.env.
PASSED_SIGN_ID="$REDPEN_SIGN_ID"
[[ -f .local.env ]] && source ./.local.env
[[ -n "$PASSED_SIGN_ID" ]] && REDPEN_SIGN_ID="$PASSED_SIGN_ID"
BUNDLE_ID="${REDPEN_BUNDLE_ID:-io.github.redpen-mac.Redpen}"
SIGN_ID="${REDPEN_SIGN_ID:--}"   # "-" is an ad-hoc signature

# Apple's on-device model needs the full Xcode toolchain, not just the Command Line Tools.
if [[ ! -d /Applications/Xcode.app ]]; then
  echo "Redpen needs Xcode (free from the Mac App Store). Install it, open it once, then run this again."
  exit 1
fi
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release --product Redpen

APP=build/Redpen.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Redpen "$APP/Contents/MacOS/Redpen"
# Newsreader, the card and panel serif (SIL Open Font License, Resources/Fonts/OFL.txt).
mkdir -p "$APP/Contents/Resources"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Redpen</string>
  <key>CFBundleExecutable</key><string>Redpen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Redpen reads the text you type to check it.</string>
</dict></plist>
PLIST
if [[ "$SIGN_ID" == Developer\ ID* ]]; then
  # A download for other Macs: hardened runtime and a secure timestamp, which Apple's notary service requires.
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
else
  codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
fi
if [[ "$SIGN_ID" == "-" ]]; then
  echo "Note: ad-hoc signed. macOS may ask you to allow Accessibility again after each rebuild."
fi
[[ -n "$REDPEN_SKIP_INSTALL" ]] && exit 0
rm -rf ~/Applications/Redpen.app
mkdir -p ~/Applications
cp -R "$APP" ~/Applications/Redpen.app
echo "Installed ~/Applications/Redpen.app"
# A running copy keeps the old code until it restarts, so restart it.
if pgrep -x Redpen >/dev/null; then
  pkill -x Redpen; sleep 1; open ~/Applications/Redpen.app
  echo "Restarted Redpen with the new build"
fi
