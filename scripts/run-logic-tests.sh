#!/bin/zsh
# Runs WheelConvertTests without an XCTest host (no testmanagerd, works headless/locked):
# compiles the tests with the sources they exercise and a minimal XCTest-compatible shim.
set -euo pipefail
ROOT=${0:A:h:h}
OUT=$ROOT/build/logic-tests
rm -rf $OUT && mkdir -p $OUT
for f in $ROOT/WheelConvertTests/*.swift; do
  sed -e '/^@testable import WheelConvert/d' -e 's/^import XCTest/import AppKit/' $f > $OUT/${f:t}
done
cat > $OUT/Shim.swift <<'SHIM'
import Foundation
class XCTestCase { required init() {} }
var failures = 0
var assertions = 0
func XCTFail(_ message: String = "", file: StaticString = #file, line: UInt = #line) { failures += 1; print("  ✗ \(file):\(line) \(message)") }
func XCTAssertTrue(_ v: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    assertions += 1; if (try? v()) != true { XCTFail(m(), file: file, line: line) }
}
func XCTAssertFalse(_ v: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    assertions += 1; if (try? v()) != false { XCTFail(m(), file: file, line: line) }
}
func XCTAssertNil<T>(_ v: @autoclosure () throws -> T?, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    assertions += 1; if let value = try? v() { XCTFail("expected nil, got \(value) \(m())", file: file, line: line) }
}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    assertions += 1
    do { let x = try a(), y = try b(); if x != y { XCTFail("\(x) != \(y) \(m())", file: file, line: line) } } catch { XCTFail("threw \(error)", file: file, line: line) }
}
func XCTAssertEqual(_ a: @autoclosure () throws -> Double, _ b: @autoclosure () throws -> Double, accuracy: Double, file: StaticString = #file, line: UInt = #line) {
    assertions += 1
    if let x = try? a(), let y = try? b(), abs(x - y) <= accuracy { return }
    XCTFail("not within \(accuracy)", file: file, line: line)
}
func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    assertions += 1; if (try? a()) == (try? b()) { XCTFail("values are equal", file: file, line: line) }
}
func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    assertions += 1; if let x = try? a(), let y = try? b(), x > y { return }; XCTFail("not greater", file: file, line: line)
}
func XCTAssertThrowsError<T>(_ e: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    assertions += 1; if (try? e()) != nil { XCTFail("did not throw", file: file, line: line) }
}
SHIM
# Test methods are discovered from the sources and called in order.
python3 -I - $OUT <<'PY'
import re, sys, os, glob
out = sys.argv[1]
calls = []
for path in sorted(glob.glob(os.path.join(out, "*Tests.swift"))):
    text = open(path).read()
    for cls in re.findall(r"final class (\w+): XCTestCase", text):
        body = text.split(f"final class {cls}", 1)[1]
        for name in re.findall(r"func (test\w+)\(\)", body):
            calls.append(f'print("{cls}.{name}"); do {{ let t = {cls}(); try t.{name}() }} catch {{ XCTFail("threw \\(error)") }}')
open(os.path.join(out, "main.swift"), "w").write("\n".join(calls) + '\nprint("\\(assertions) assertions, \\(failures) failures"); exit(failures == 0 ? 0 : 1)\n')
PY
SRC=$ROOT/WheelConvert
SOURCES=(${(f)"$(find $SRC -name '*.swift' ! -path '*/App/main.swift')"})
# Sparkle comes from the app build's package checkout (scripts/build.sh).
SPARKLE=$ROOT/build/DD/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64
[[ -d $SPARKLE ]] || { echo "Run scripts/build.sh first (it downloads Sparkle)"; exit 1; }
swiftc -O -module-name WheelConvert -import-objc-header $SRC/Support/WheelConvert-Bridging-Header.h -I $ROOT/Vendor/build/deps/include \
  -L $ROOT/Vendor/build/deps/lib -lwebpmux -lwebp -lsharpyuv -lz -F $SPARKLE -framework Sparkle -Xlinker -rpath -Xlinker $SPARKLE \
  -o $OUT/run $SOURCES $OUT/*.swift 2>&1 | grep -E "error:" | head -20 || true
$OUT/run
