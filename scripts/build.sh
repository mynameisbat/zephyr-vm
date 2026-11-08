#!/bin/bash
# Builds Zephyr.app and zephyrctl, signed (ad-hoc) with the virtualization entitlement.
#   scripts/build.sh            # debug
#   CONFIG=release scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-debug}
# The macOS 27 SDK turns SwiftUI's @State into a macro whose plugin ships only with Xcode;
# with Command Line Tools alone, build against the newest SDK that predates it.
if [ -z "${SDKROOT:-}" ] && [ ! -d "$(xcode-select -p)/Platforms" ]; then
    for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
        if [ -d "$sdk" ]; then export SDKROOT="$sdk"; break; fi
    done
fi

swift build -c "$CONFIG"
BIN=".build/$CONFIG"
ENT=Resources/Zephyr.entitlements

codesign --force --sign - --entitlements "$ENT" "$BIN/zephyrctl"

APP=build/Zephyr.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Zephyr" "$APP/Contents/MacOS/Zephyr"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
    swift scripts/make-icon.swift "$PWD" >/dev/null
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --entitlements "$ENT" "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1)) and $BIN/zephyrctl"
