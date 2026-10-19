#!/bin/zsh
# Builds static, LGPL-only ffmpeg + ffprobe + cwebp for arm64 macOS 13+.
# Output: Vendor/build/bin/{ffmpeg,ffprobe,cwebp} and Vendor/build/licenses/.
set -euo pipefail

ROOT=${0:A:h:h}
SRC=$ROOT/Vendor/src
PREFIX=$ROOT/Vendor/build/deps
OUT=$ROOT/Vendor/build
JOBS=$(sysctl -n hw.ncpu)
MIN=13.0
SDK=$(xcrun --sdk macosx --show-sdk-path)
export CC="$(xcrun -f clang)" CXX="$(xcrun -f clang++)"
export CFLAGS="-arch arm64 -mmacosx-version-min=$MIN -isysroot $SDK -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch arm64 -mmacosx-version-min=$MIN -isysroot $SDK"
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
export MACOSX_DEPLOYMENT_TARGET=$MIN

FFMPEG=9.0.1 LAME=3.100 VPX=1.17.0 OPUS=1.6.1 OGG=1.3.6 VORBIS=1.3.7 WEBP=1.6.0

mkdir -p $SRC $PREFIX $OUT/bin $OUT/licenses
cd $SRC

fetch() { # url file sha256 — pinned for the versions above; update together with a version bump
  [[ -f $2 ]] || { curl -fL --retry 3 -o $2.part "$1" && mv $2.part $2; }
  [[ $(shasum -a 256 $2 | cut -d' ' -f1) == $3 ]] || { echo "Checksum mismatch for $2"; rm -f $2; exit 1; }
}
fetch https://ffmpeg.org/releases/ffmpeg-$FFMPEG.tar.xz ffmpeg-$FFMPEG.tar.xz cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635
fetch https://downloads.sourceforge.net/project/lame/lame/$LAME/lame-$LAME.tar.gz lame-$LAME.tar.gz ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
fetch https://github.com/webmproject/libvpx/archive/refs/tags/v$VPX.tar.gz libvpx-$VPX.tar.gz 1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a
fetch https://downloads.xiph.org/releases/opus/opus-$OPUS.tar.gz opus-$OPUS.tar.gz 6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
fetch https://downloads.xiph.org/releases/ogg/libogg-$OGG.tar.xz libogg-$OGG.tar.xz 5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061
fetch https://downloads.xiph.org/releases/vorbis/libvorbis-$VORBIS.tar.xz libvorbis-$VORBIS.tar.xz b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b
fetch https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$WEBP.tar.gz libwebp-$WEBP.tar.gz e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564

unpack() { [[ -d $2 ]] || tar -xf $1; }
unpack ffmpeg-$FFMPEG.tar.xz ffmpeg-$FFMPEG
unpack lame-$LAME.tar.gz lame-$LAME
unpack libvpx-$VPX.tar.gz libvpx-$VPX
unpack opus-$OPUS.tar.gz opus-$OPUS
unpack libogg-$OGG.tar.xz libogg-$OGG
unpack libvorbis-$VORBIS.tar.xz libvorbis-$VORBIS
unpack libwebp-$WEBP.tar.gz libwebp-$WEBP

autotools() { # dir extra-args...
  local dir=$1; shift
  [[ -f $dir/.built ]] && return
  ( cd $dir && ./configure --host=aarch64-apple-darwin --prefix=$PREFIX --disable-shared --enable-static "$@" \
      && make -j$JOBS && make install ) && touch $dir/.built
}

# LAME's configure probes a symbol list that clang rejects; drop it.
sed -i '' '/lame_init_old/d' lame-$LAME/include/libmp3lame.sym 2>/dev/null || true
# LAME 3.100 predates C99-strict clang; give it the headers it forgets to include.
CFLAGS="$CFLAGS -include string.h -include strings.h -Wno-implicit-function-declaration" autotools lame-$LAME --disable-frontend --disable-decoder
autotools libogg-$OGG
# libvorbis 1.3.7 passes a linker flag modern ld rejects.
sed -i '' 's/-force_cpusubtype_ALL//g' libvorbis-$VORBIS/configure
autotools libvorbis-$VORBIS --with-ogg=$PREFIX --disable-examples
autotools opus-$OPUS --disable-doc --disable-extra-programs
autotools libwebp-$WEBP --disable-gl --disable-sdl --disable-png --disable-jpeg --disable-tiff --disable-gif --enable-libwebpmux --enable-libwebpdemux

if [[ ! -f libvpx-$VPX/.built ]]; then
  ( cd libvpx-$VPX && ./configure --target=arm64-darwin22-gcc --prefix=$PREFIX --disable-shared --enable-static \
      --disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-vp8 --enable-vp9 \
      --enable-pic --extra-cflags="$CFLAGS" && make -j$JOBS && make install ) && touch libvpx-$VPX/.built
fi

# cwebp CLI (used for exact target-size WebP compression), linked against the static libwebp.
# cwebp reads PAM input, which WheelConvert writes itself, so no PNG/JPEG decoders are needed.
cp $PREFIX/bin/cwebp $OUT/bin/cwebp

if [[ ! -f ffmpeg-$FFMPEG/.built ]]; then
  ( cd ffmpeg-$FFMPEG && ./configure \
      --cc="$CC" --host-cc="$CC" --host-cflags="-isysroot $SDK -O2" --host-ldflags="-isysroot $SDK" --arch=arm64 --target-os=darwin --prefix=$PREFIX/ffmpeg \
      --extra-cflags="$CFLAGS -I$PREFIX/include" --extra-ldflags="$LDFLAGS -L$PREFIX/lib" \
      --pkg-config=pkg-config --pkg-config-flags=--static --extra-libs=-liconv \
      --disable-shared --enable-static --disable-autodetect --disable-doc --disable-debug \
      --disable-network --disable-ffplay --enable-ffprobe \
      --enable-audiotoolbox --enable-videotoolbox --enable-zlib --enable-bzlib --enable-iconv \
      --enable-libmp3lame --enable-libwebp --enable-libvpx --enable-libopus --enable-libvorbis \
      && make -j$JOBS ) && touch ffmpeg-$FFMPEG/.built
fi
cp ffmpeg-$FFMPEG/ffmpeg ffmpeg-$FFMPEG/ffprobe $OUT/bin/
strip -x $OUT/bin/ffmpeg $OUT/bin/ffprobe $OUT/bin/cwebp 2>/dev/null || true

cp ffmpeg-$FFMPEG/COPYING.LGPLv2.1 $OUT/licenses/FFmpeg-LGPL-2.1.txt
cp lame-$LAME/COPYING $OUT/licenses/LAME-LGPL.txt
cp libvpx-$VPX/LICENSE $OUT/licenses/libvpx-BSD.txt
cp opus-$OPUS/COPYING $OUT/licenses/Opus-BSD.txt
cp libogg-$OGG/COPYING $OUT/licenses/libogg-BSD.txt
cp libvorbis-$VORBIS/COPYING $OUT/licenses/libvorbis-BSD.txt
cp libwebp-$WEBP/COPYING $OUT/licenses/libwebp-BSD.txt

echo "== built"; file $OUT/bin/*; otool -L $OUT/bin/ffmpeg | sed 1d
$OUT/bin/ffmpeg -hide_banner -version | head -1
