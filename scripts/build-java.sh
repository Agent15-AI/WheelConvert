#!/bin/zsh
# Builds the Office helper: a jlink'd Java 21 runtime, the Apache POI / PDFBox jars it needs,
# and WheelConvertOffice.jar compiled from java/src.
# Output: Vendor/build/java/{runtime,lib}
set -euo pipefail

ROOT=${0:A:h:h}
OUT=$ROOT/Vendor/build/java
JDK=${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}
MAVEN=https://repo1.maven.org/maven2

# group:artifact:version — Apache POI 5.5.1's runtime closure plus PDFBox and its Graphics2D bridge.
JARS=(
  org.apache.poi:poi:5.5.1
  org.apache.poi:poi-ooxml:5.5.1
  org.apache.poi:poi-ooxml-lite:5.5.1
  org.apache.poi:poi-scratchpad:5.5.1
  org.apache.xmlbeans:xmlbeans:5.3.0
  org.apache.commons:commons-collections4:4.5.0
  org.apache.commons:commons-compress:1.28.0
  org.apache.commons:commons-math3:3.6.1
  org.apache.commons:commons-lang3:3.18.0
  commons-io:commons-io:2.21.0
  commons-codec:commons-codec:1.20.0
  com.zaxxer:SparseBitSet:1.3
  com.github.virtuald:curvesapi:1.08
  org.apache.logging.log4j:log4j-api:2.24.3
  org.apache.pdfbox:pdfbox:3.0.8
  org.apache.pdfbox:pdfbox-io:3.0.8
  org.apache.pdfbox:fontbox:3.0.8
  commons-logging:commons-logging:1.3.5
  de.rototor.pdfbox:graphics2d:3.0.5
)

mkdir -p $OUT/lib $ROOT/Vendor/src/java
for coord in $JARS; do
  IFS=: read -r g a v <<< "$coord"
  jar=$a-$v.jar
  [[ -f $OUT/lib/$jar ]] && continue
  url=$MAVEN/${g//.//}/$a/$v/$jar
  curl -fsSL --retry 3 -o $OUT/lib/$jar.part $url
  expected=$(curl -fsSL $url.sha1 | cut -c1-40)
  actual=$(shasum -a 1 $OUT/lib/$jar.part | cut -c1-40)
  [[ $expected == $actual ]] || { echo "SHA1 mismatch for $jar"; rm $OUT/lib/$jar.part; exit 1; }
  mv $OUT/lib/$jar.part $OUT/lib/$jar
done

# Compile the helper against the jars.
CP=$(print -l $OUT/lib/*.jar | grep -v WheelConvertOffice | paste -sd: -)
CLASSES=$ROOT/Vendor/src/java/classes
rm -rf $CLASSES && mkdir -p $CLASSES
$JDK/bin/javac --release 21 -encoding UTF-8 -nowarn -cp $CP -d $CLASSES $ROOT/java/src/*.java
$JDK/bin/jar --create --file $OUT/lib/WheelConvertOffice.jar --main-class WheelConvertOffice -C $CLASSES .

# Minimal runtime: just the modules POI/PDFBox rendering needs.
if [[ ! -x $OUT/runtime/bin/java ]]; then
  rm -rf $OUT/runtime
  $JDK/bin/jlink --add-modules java.base,java.datatransfer,java.xml,java.prefs,java.desktop,java.logging,jdk.unsupported \
    --strip-debug --no-man-pages --no-header-files --compress=zip-6 --output $OUT/runtime
fi
echo "== java helper ready"; $OUT/runtime/bin/java -version 2>&1 | head -1; du -sh $OUT/runtime $OUT/lib
