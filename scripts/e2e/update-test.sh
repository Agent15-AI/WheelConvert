#!/bin/zsh
# End-to-end Sparkle check: builds two ad-hoc signed Release copies (1.0.0 and 1.0.1) under a test
# bundle identifier with a throwaway EdDSA key, serves a signed appcast from 127.0.0.1, launches the old
# copy and waits for Sparkle to download, verify and install the new one.
# It leaves the real app's settings alone and removes its own; it briefly shows a second WheelConvert icon in the menu bar.
set -euo pipefail
ROOT=${0:A:h:h:h}
WORK=$ROOT/build/update-test
BUNDLE=app.wheelconvert.UpdateTest
PORT=8931
rm -rf $WORK && mkdir -p $WORK/feed $WORK/old
cd $ROOT
xcodegen generate --quiet

# A throwaway key pair: the base64 seed (what generate_keys -x exports) and its public key.
KEYS=$(swift - <<'SWIFT'
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)
SEED=${KEYS% *} PUBLIC=${KEYS#* }

build() {  # version, build number
  xcodebuild -project WheelConvert.xcodeproj -scheme WheelConvert -configuration Release -derivedDataPath $WORK/dd \
    PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE MARKETING_VERSION=$1 CURRENT_PROJECT_VERSION=$2 SPARKLE_PUBLIC_KEY=$PUBLIC \
    SPARKLE_FEED_URL=http://127.0.0.1:$PORT/appcast.xml build 2>&1 | grep -E 'error: |\*\* BUILD' | sort -u
}
APP=$WORK/dd/Build/Products/Release/WheelConvert.app
SIGN=$WORK/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update

build 1.0.1 101
codesign --verify --deep --strict $APP
hdiutil create -volname "WheelConvert 1.0.1" -srcfolder $APP -fs APFS -format ULFO -ov $WORK/feed/WheelConvert-1.0.1.dmg >/dev/null 2>&1
SIGNATURE=$(print -r -- $SEED | $SIGN --ed-key-file - -p $WORK/feed/WheelConvert-1.0.1.dmg)
LENGTH=$(stat -f %z $WORK/feed/WheelConvert-1.0.1.dmg)
cat > $WORK/feed/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>WheelConvert</title>
    <item>
      <title>Version 1.0.1</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>101</sparkle:version>
      <sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="http://127.0.0.1:$PORT/WheelConvert-1.0.1.dmg" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
XML
print -r -- $SEED | $SIGN --ed-key-file - $WORK/feed/appcast.xml

build 1.0.0 100
ditto $APP $WORK/old/WheelConvert.app

# Fresh settings for the test identifier: no welcome window, update without asking.
defaults delete $BUNDLE >/dev/null 2>&1 || true
defaults write $BUNDLE hasCompletedWelcome -bool true
defaults write $BUNDLE SUAutomaticallyUpdate -bool true
defaults write $BUNDLE SUEnableAutomaticChecks -bool true
# A fresh install waits a day before its first scheduled check; an old last check makes one due now.
defaults write $BUNDLE SULastCheckTime -date "2020-01-01 00:00:00 +0000"

python3 -I -m http.server $PORT --bind 127.0.0.1 --directory $WORK/feed > $WORK/server.log 2>&1 &
SERVER=$!
cleanup() {
  set +e  # pkill finds nothing once the app has quit; keep cleaning up anyway.
  kill $SERVER 2>/dev/null
  pkill -f "$WORK/old/WheelConvert.app/Contents/MacOS/WheelConvert" 2>/dev/null
  sleep 2  # Sparkle's installer saves its last settings as it exits.
  defaults delete $BUNDLE >/dev/null 2>&1
  rm -rf ~/Library/Caches/$BUNDLE ~/Library/HTTPStorages/$BUNDLE ~/Library/Preferences/$BUNDLE.plist
}
trap cleanup EXIT

$WORK/old/WheelConvert.app/Contents/MacOS/WheelConvert > $WORK/app.log 2>&1 &
APPPID=$!
# Sparkle checks shortly after launch, downloads and verifies, then installs once the app quits.
for _ in {1..60}; do grep -q "GET /WheelConvert-1.0.1.dmg" $WORK/server.log && break; sleep 1; done
grep -q "GET /WheelConvert-1.0.1.dmg" $WORK/server.log || { echo "FAIL: Sparkle never downloaded the update"; cat $WORK/server.log; exit 1; }
sleep 8
kill -TERM $APPPID 2>/dev/null || true
for _ in {1..60}; do
  [[ $(defaults read $WORK/old/WheelConvert.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null) == 1.0.1 ]] && break
  sleep 1
done
VERSION=$(defaults read $WORK/old/WheelConvert.app/Contents/Info.plist CFBundleShortVersionString)
if [[ $VERSION == 1.0.1 ]] && codesign --verify --deep --strict $WORK/old/WheelConvert.app; then
  echo "OK: Sparkle updated the ad-hoc signed app from 1.0.0 to $VERSION and its signature verifies"
else
  echo "FAIL: app is still $VERSION"; log show --last 3m --style compact --predicate 'subsystem == "org.sparkle-project.Sparkle"' 2>/dev/null | tail -20
  exit 1
fi
