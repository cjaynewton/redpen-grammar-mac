#!/bin/zsh
# Builds the download version of Redpen Grammar: a signed, notarized Redpen-Grammar.dmg that opens on any Mac with macOS 26,
# no Xcode or Homebrew needed. For maintainers; users of the source code run ./install.sh instead.
#
# Needs, once:
#   1. A "Developer ID Application" certificate (Xcode > Settings > Accounts > Manage Certificates > +).
#   2. Notary credentials saved under the name "redpen":
#        xcrun notarytool store-credentials redpen --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#      (it asks for an app-specific password from account.apple.com).
set -e
cd "${0:A:h}"
[[ -f .local.env ]] && source ./.local.env
ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
if [[ -z "$ID" ]]; then
  echo "No Developer ID Application certificate on this Mac. See the note at the top of release.sh."
  exit 1
fi
if ! xcrun notarytool history --keychain-profile redpen >/dev/null 2>&1; then
  echo "No notary credentials named \"redpen\". See the note at the top of release.sh."
  exit 1
fi

REDPEN_SIGN_ID="$ID" REDPEN_SKIP_INSTALL=1 ./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "build/Redpen Grammar.app/Contents/Info.plist")
STAGE=build/dmg
rm -rf "$STAGE" "build/Redpen-Grammar-$VERSION.dmg"
mkdir -p "$STAGE"
cp -R "build/Redpen Grammar.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Redpen Grammar" -srcfolder "$STAGE" -format UDZO "build/Redpen-Grammar-$VERSION.dmg" >/dev/null
codesign --force --timestamp --sign "$ID" "build/Redpen-Grammar-$VERSION.dmg"

echo "Sending to Apple's notary service (a few minutes)..."
xcrun notarytool submit "build/Redpen-Grammar-$VERSION.dmg" --keychain-profile redpen --wait
xcrun stapler staple "build/Redpen-Grammar-$VERSION.dmg"
spctl --assess --type open --context context:primary-signature -v "build/Redpen-Grammar-$VERSION.dmg"
echo "Ready: build/Redpen-Grammar-$VERSION.dmg"
echo "Publish it as a GitHub release: gh release create v$VERSION build/Redpen-Grammar-$VERSION.dmg"
