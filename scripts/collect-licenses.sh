#!/bin/zsh
# Gathers license and notice texts of the bundled Java and JavaScript libraries and ExifTool into
# Vendor/build/licenses (embed-vendor.sh copies that folder into the app). FFmpeg and codec
# licenses are placed there by build-ffmpeg.sh.
set -euo pipefail
setopt extendedglob
ROOT=${0:A:h:h}
OUT=$ROOT/Vendor/build/licenses
mkdir -p $OUT/Java $OUT/JavaScript

for jar in $ROOT/Vendor/build/java/lib/*.jar; do
  name=${jar:t:r}
  [[ $name == WheelConvertOffice ]] && continue
  for entry in $(unzip -Z1 $jar | grep -E '^META-INF/(LICENSE|NOTICE)(\.txt|\.md)?$' || true); do
    unzip -p $jar $entry > $OUT/Java/$name-${${entry:t}:r}.txt
  done
done

for dir in $ROOT/js/node_modules/*(/); do
  [[ ${dir:t} == (esbuild|@esbuild) ]] && continue  # build tool, not shipped
  file=$(print -l $dir/(#i)(license|licence|copying)*(N.) | head -1)
  [[ -n $file ]] && cp $file $OUT/JavaScript/${dir:t}-LICENSE.txt
done

sed -n '/^COPYRIGHT AND LICENSE/,/^DISTRIBUTION FILES/p' $ROOT/Vendor/build/ExifTool/README | sed '$d' > $OUT/ExifTool-LICENSE.txt
echo "== licenses"; find $OUT -type f | sed "s|$OUT/||" | sort
