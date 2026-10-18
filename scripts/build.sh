#!/bin/zsh
# Quiet Debug build: prints only diagnostics and the result line.
cd ${0:A:h:h}
xcodegen generate --quiet >/dev/null
xcodebuild -project WheelConvert.xcodeproj -scheme WheelConvert -configuration ${CONFIG:-Debug} -derivedDataPath build/DD ${@:-build} 2>&1 \
  | grep -E '(error|warning): |^\*\* (BUILD|TEST)|Test Case .* (failed|passed)|Executed [0-9]+ test' | grep -v 'CoreSimulator' | sort -u
