#!/bin/zsh
# Builds Redpen Grammar.app and installs it to ~/Applications.
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
# The public half of the key that signs each update (the private half stays in the maintainer's keychain).
SPARKLE_PUBLIC_KEY="W6ZRcpaIC2RR+xBtiP1ixtreKsoX+MptojZaqzyg+ZU="
SIGN_ID="${REDPEN_SIGN_ID:--}"   # "-" is an ad-hoc signature

# Apple's on-device model needs the full Xcode toolchain, not just the Command Line Tools.
if [[ ! -d /Applications/Xcode.app ]]; then
  echo "Redpen needs Xcode (free from the Mac App Store). Install it, open it once, then run this again."
  exit 1
fi
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# One app for Apple chips and Intel Macs. Intel Macs never get Apple Intelligence; the rest of Redpen runs the same.
swift build -c release --product Redpen --arch arm64 --arch x86_64

APP="build/Redpen Grammar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp .build/out/Products/Release/Redpen "$APP/Contents/MacOS/Redpen"
# Sparkle, for one-click updates. Redpen is not sandboxed, so Sparkle's two helper services for sandboxed apps are left out.
cp -R .build/out/Products/Release/Sparkle.framework "$APP/Contents/Frameworks/"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
# Newsreader, the card and panel serif (SIL Open Font License, Resources/Fonts/OFL.txt).
mkdir -p "$APP/Contents/Resources"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
# The app icon: a Gloock "r." in the Retail Dark palette (Resources/Icon/icon-source.html is the drawing).
cp Resources/Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Redpen Grammar</string>
  <key>CFBundleExecutable</key><string>Redpen</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.8</string>
  <key>CFBundleVersion</key><string>8</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>SUFeedURL</key><string>https://github.com/cjaynewton/redpen-grammar-mac/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Redpen reads the text you type to check it.</string>
</dict></plist>
PLIST
if [[ "$SIGN_ID" == Developer\ ID* ]]; then
  # A download for other Macs: hardened runtime and a secure timestamp, which Apple's notary service requires.
  # Inside out: Sparkle's helpers, then Sparkle, then the app.
  SP="$APP/Contents/Frameworks/Sparkle.framework"
  for part in "$SP/Versions/B/Autoupdate" "$SP/Versions/B/Updater.app" "$SP"; do
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$part"
  done
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
else
  SP="$APP/Contents/Frameworks/Sparkle.framework"
  for part in "$SP/Versions/B/Autoupdate" "$SP/Versions/B/Updater.app" "$SP"; do
    codesign --force --sign "$SIGN_ID" "$part"
  done
  codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
fi
if [[ "$SIGN_ID" == "-" ]]; then
  echo "Note: ad-hoc signed. macOS may ask you to allow Accessibility again after each rebuild."
fi
[[ -n "$REDPEN_SKIP_INSTALL" ]] && exit 0
# Before Oct 17 2026 the app was called Redpen.app; remove that copy so only one is installed.
rm -rf ~/Applications/Redpen.app ~/Applications/"Redpen Grammar.app"
mkdir -p ~/Applications
cp -R "$APP" ~/Applications/"Redpen Grammar.app"
echo "Installed ~/Applications/Redpen Grammar.app"
# A running copy keeps the old code until it restarts, so restart it.
if pgrep -x Redpen >/dev/null; then
  pkill -x Redpen; sleep 1; open ~/Applications/"Redpen Grammar.app"
  echo "Restarted Redpen with the new build"
fi
