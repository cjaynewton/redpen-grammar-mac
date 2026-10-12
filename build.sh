#!/bin/zsh
# Builds Redpen.app and installs it to ~/Applications.
#
# Optional, in a .local.env file next to this script (not committed):
#   REDPEN_SIGN_ID="Apple Development"   # sign with your certificate so Accessibility survives rebuilds
#   REDPEN_BUNDLE_ID="com.example.redpen"
set -e
cd "${0:A:h}"
[[ -f .local.env ]] && source ./.local.env
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
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Redpen</string>
  <key>CFBundleExecutable</key><string>Redpen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Redpen reads the text you type to check it.</string>
</dict></plist>
PLIST
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
if [[ "$SIGN_ID" == "-" ]]; then
  echo "Note: ad-hoc signed. macOS may ask you to allow Accessibility again after each rebuild."
fi
rm -rf ~/Applications/Redpen.app
mkdir -p ~/Applications
cp -R "$APP" ~/Applications/Redpen.app
echo "Installed ~/Applications/Redpen.app"
