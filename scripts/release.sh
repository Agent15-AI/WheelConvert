#!/bin/zsh
# Builds a release into dist/: WheelConvert-<version>.dmg with its SHA-256, a signed Sparkle appcast.xml,
# plus the source tarballs of the LGPL components, and points Casks/wheelconvert.rb at it.
# The disk image is signed with the Sparkle EdDSA key from $SPARKLE_PRIVATE_KEY (the GitHub secret) or,
# without it, from this Mac's keychain (generate_keys). README → Releasing explains the keys.
# usage: scripts/release.sh <version>      (run the vendor build steps in README.md first)
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
VERSION=${1:?usage: scripts/release.sh <version, e.g. 1.0.0>}
[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.2.3"; exit 1; }
for f in Vendor/build/bin/ffmpeg Vendor/build/java/runtime/bin/java Vendor/build/ExifTool/exiftool Vendor/build/js/pages-bridge.js; do
  [[ -e $f ]] || { echo "Missing $f; run the vendor build steps in README.md first"; exit 1; }
done

grep -qE '^    SPARKLE_PUBLIC_KEY: "?[A-Za-z0-9+/=]{40,}' project.yml || { echo "Set SPARKLE_PUBLIC_KEY in project.yml first (README → Releasing)"; exit 1; }
[[ -z ${GITHUB_ACTIONS:-} || -n ${SPARKLE_PRIVATE_KEY:-} ]] || { echo "The SPARKLE_PRIVATE_KEY secret is missing (README → Releasing)"; exit 1; }
BUILD=$(git rev-list --count HEAD)
REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##' || true)

zsh scripts/collect-licenses.sh >/dev/null
xcodegen generate --quiet
xcodebuild -project WheelConvert.xcodeproj -scheme WheelConvert -configuration Release -derivedDataPath build/release \
  MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$BUILD build 2>&1 \
  | grep -E '(error|warning): |^\*\* BUILD' | grep -v appintents | sort -u
APP=build/release/Build/Products/Release/WheelConvert.app
codesign --verify --deep --strict $APP

# Drag-to-install disk image: the app next to an Applications shortcut.
mkdir -p dist
DMG=dist/WheelConvert-$VERSION.dmg
STAGE=$(mktemp -d)
cp -R $APP $STAGE/
ln -s /Applications $STAGE/Applications
hdiutil create -volname "WheelConvert $VERSION" -srcfolder $STAGE -fs APFS -format ULFO -ov $DMG >/dev/null
rm -rf $STAGE
SHA=$(shasum -a 256 $DMG | cut -d' ' -f1)
echo "$SHA  ${DMG:t}" > $DMG.sha256

# Sparkle: sign the disk image, check the signature against the public key inside the app (so installed
# copies will accept it), and publish a signed appcast. The release workflow uploads it with the image,
# and the app's feed URL points at the latest release's appcast.xml.
SIGN=build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
sparkle_sign() { if [[ -n ${SPARKLE_PRIVATE_KEY:-} ]]; then print -r -- $SPARKLE_PRIVATE_KEY | $SIGN --ed-key-file - "$@"; else $SIGN "$@"; fi }
SIGNATURE=$(sparkle_sign -p $DMG)
PUBLIC=$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" $APP/Contents/Info.plist)
DMG_PATH=$DMG SIGNATURE=$SIGNATURE PUBLIC=$PUBLIC swift - <<'SWIFT' || { echo "The Sparkle signature doesn't match SPARKLE_PUBLIC_KEY in project.yml"; exit 1; }
import CryptoKit
import Foundation
let env = ProcessInfo.processInfo.environment
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: env["PUBLIC"]!)!)
let data = try Data(contentsOf: URL(fileURLWithPath: env["DMG_PATH"]!), options: .mappedIfSafe)
exit(key.isValidSignature(Data(base64Encoded: env["SIGNATURE"]!)!, for: data) ? 0 : 1)
SWIFT
cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>WheelConvert</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/${DMG:t}" length="$(stat -f %z $DMG)" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
XML
sparkle_sign dist/appcast.xml

# LGPL 2.1 asks that binaries come with their source; these are the exact tarballs that were built.
cp Vendor/src/ffmpeg-*.tar.xz Vendor/src/lame-*.tar.gz dist/

# Homebrew cask for this release; the GitHub owner/repo comes from the origin remote.
sed -i '' -E -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/wheelconvert.rb
[[ -n $REPO ]] && sed -i '' -E "s#github\.com/[^/]+/[^/]+/releases#github.com/$REPO/releases#; s#homepage \"https://github\.com/[^\"]+\"#homepage \"https://github.com/$REPO\"#" Casks/wheelconvert.rb

echo "== dist"; ls -lh dist
echo "Casks/wheelconvert.rb now points at v$VERSION${REPO:+ on $REPO}. Commit it, then publish dist/* as release v$VERSION."
