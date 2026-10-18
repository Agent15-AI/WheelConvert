#!/bin/zsh
# Xcode build phase: copies the vendor tools into WheelConvert.app/Contents/Resources and signs
# every nested Mach-O so the outer app signature is valid.
set -euo pipefail
VENDOR="$PROJECT_DIR/Vendor/build"
RES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
for f in "$VENDOR/bin/ffmpeg" "$VENDOR/bin/ffprobe" "$VENDOR/ExifTool/exiftool" "$VENDOR/java/runtime/bin/java" "$VENDOR/java/lib/WheelConvertOffice.jar" "$VENDOR/js/pages-bridge.js" "$VENDOR/js/docx-render.js"; do
  [[ -e $f ]] || { echo "error: missing $f — run scripts/build-*.sh first"; exit 1; }
done
mkdir -p "$RES/Tools" "$RES/Office" "$RES/JS" "$RES/Licenses"
rsync -a --delete "$VENDOR/bin/ffmpeg" "$VENDOR/bin/ffprobe" "$RES/Tools/"
rsync -a --delete "$VENDOR/ExifTool/" "$RES/Tools/ExifTool/"
rsync -a --delete "$VENDOR/java/runtime/" "$RES/Office/runtime/"
rsync -a --delete "$VENDOR/java/lib/" "$RES/Office/lib/"
rsync -a --delete "$VENDOR/js/" "$RES/JS/"
rsync -a "$VENDOR/licenses/" "$RES/Licenses/"
cp "$PROJECT_DIR/THIRD-PARTY-NOTICES.md" "$RES/Licenses/" 2>/dev/null || true

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -z "$IDENTITY" ]] && IDENTITY="-"
sign() { codesign --force --sign "$IDENTITY" --timestamp=none "$@" >/dev/null; }
sign --options runtime "$RES/Tools/ffmpeg"
sign --options runtime "$RES/Tools/ffprobe"
# Java needs JIT and loads its own unsigned-by-team libraries.
find "$RES/Office/runtime" -type f \( -name '*.dylib' -o -perm +111 \) -print0 | while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then
    if [[ "$f" == */bin/java || "$f" == */jspawnhelper ]]; then
      sign --options runtime --entitlements "$PROJECT_DIR/scripts/java-entitlements.plist" "$f"
    else
      sign "$f"
    fi
  fi
done
