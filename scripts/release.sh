#!/bin/zsh
# Builds a release into dist/: WheelConvert-<version>.dmg with its SHA-256, plus the source tarballs
# of the LGPL components, and points Casks/wheelconvert.rb at it.
# usage: scripts/release.sh <version>      (run the vendor build steps in README.md first)
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
VERSION=${1:?usage: scripts/release.sh <version, e.g. 1.0.0>}
[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.2.3"; exit 1; }
for f in Vendor/build/bin/ffmpeg Vendor/build/java/runtime/bin/java Vendor/build/ExifTool/exiftool Vendor/build/js/pages-bridge.js; do
  [[ -e $f ]] || { echo "Missing $f; run the vendor build steps in README.md first"; exit 1; }
done

zsh scripts/collect-licenses.sh >/dev/null
xcodegen generate --quiet
xcodebuild -project WheelConvert.xcodeproj -scheme WheelConvert -configuration Release -derivedDataPath build/release \
  MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD) build 2>&1 \
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

# LGPL 2.1 asks that binaries come with their source; these are the exact tarballs that were built.
cp Vendor/src/ffmpeg-*.tar.xz Vendor/src/lame-*.tar.gz dist/

# Homebrew cask for this release; the GitHub owner/repo comes from the origin remote.
REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##' || true)
sed -i '' -E -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/wheelconvert.rb
[[ -n $REPO ]] && sed -i '' -E "s#github\.com/[^/]+/[^/]+/releases#github.com/$REPO/releases#; s#homepage \"https://github\.com/[^\"]+\"#homepage \"https://github.com/$REPO\"#" Casks/wheelconvert.rb

echo "== dist"; ls -lh dist
echo "Casks/wheelconvert.rb now points at v$VERSION${REPO:+ on $REPO}. Commit it, then publish dist/* as release v$VERSION."
