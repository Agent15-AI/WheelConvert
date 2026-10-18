#!/bin/zsh
# Fetches ExifTool (Perl) for metadata reading/editing. Runs on macOS's /usr/bin/perl.
# Output: Vendor/build/ExifTool/{exiftool,lib}
set -euo pipefail
ROOT=${0:A:h:h}
VERSION=${EXIFTOOL_VERSION:-$(curl -fsSL https://exiftool.org/ver.txt)}
SRC=$ROOT/Vendor/src
OUT=$ROOT/Vendor/build/ExifTool
mkdir -p $SRC
cd $SRC
[[ -f Image-ExifTool-$VERSION.tar.gz ]] || curl -fL --retry 3 -o Image-ExifTool-$VERSION.tar.gz https://sourceforge.net/projects/exiftool/files/Image-ExifTool-$VERSION.tar.gz/download
# exiftool.org publishes SHA-256 checksums for each release.
expected=$(curl -fsSL https://exiftool.org/checksums.txt | grep -E "SHA2-256\(Image-ExifTool-$VERSION.tar.gz\)" | awk '{print $NF}')
actual=$(shasum -a 256 Image-ExifTool-$VERSION.tar.gz | cut -d' ' -f1)
[[ -n $expected && $expected == $actual ]] || { echo "ExifTool checksum mismatch ($expected vs $actual)"; exit 1; }
rm -rf Image-ExifTool-$VERSION && tar -xzf Image-ExifTool-$VERSION.tar.gz
rm -rf $OUT && mkdir -p $OUT
cp Image-ExifTool-$VERSION/exiftool $OUT/exiftool
cp -R Image-ExifTool-$VERSION/lib $OUT/lib
cp Image-ExifTool-$VERSION/README $OUT/README
chmod +x $OUT/exiftool
/usr/bin/perl $OUT/exiftool -ver
