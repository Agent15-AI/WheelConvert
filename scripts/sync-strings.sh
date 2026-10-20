#!/bin/zsh
# Merges the strings the compiler found (SWIFT_EMIT_LOC_STRINGS) into WheelConvert/Resources/Localizable.xcstrings,
# like Xcode does after a build. Run it after scripts/build.sh whenever user-facing text changes, then translate
# the new entries (Xcode's catalog editor shows what's missing).
set -euo pipefail
ROOT=${0:A:h:h}
DATA=($ROOT/build/DD/Build/Intermediates.noindex/WheelConvert.build/Debug/WheelConvert.build/Objects-normal/arm64/*.stringsdata)
xcrun xcstringstool sync $ROOT/WheelConvert/Resources/Localizable.xcstrings --stringsdata $DATA
