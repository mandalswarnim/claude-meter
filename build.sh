#!/bin/bash
# Builds Claude Usage.app (menu bar companion + WidgetKit extension)
# using only the Command Line Tools — no Xcode required.
#
# Note: this machine's CLT has a bug — usr/include/swift contains BOTH
# module.modulemap and bridging.modulemap defining module SwiftBridging,
# which breaks every clang module build ("redefinition of module").
# We work around it with a shadow toolchain (copied swiftc, symlinked
# everything else, duplicate modulemap omitted). If a CLT update fixes
# the duplication, the shim is skipped automatically.
set -euo pipefail
cd "$(dirname "$0")"

CLT=/Library/Developer/CommandLineTools
SDK="$CLT/SDKs/MacOSX.sdk"
TARGET="arm64-apple-macos15.0"
BUILD="build"
APP="$BUILD/ClaudeMeter.app"
APPEX="$APP/Contents/PlugIns/ClaudeUsageWidget.appex"

SWIFTC="$CLT/usr/bin/swiftc"
if [ -f "$CLT/usr/include/swift/module.modulemap" ] && [ -f "$CLT/usr/include/swift/bridging.modulemap" ]; then
    SHIM="$PWD/.toolchain-shim"
    # The shim *copies* swift-frontend but symlinks usr/lib, so a CLT update
    # leaves an old compiler pointed at new dylibs and it dies at launch with
    # "Symbol not found". Rebuild whenever the CLT's copy is newer than ours.
    if [ -x "$SHIM/usr/bin/swift-frontend" ] && \
       [ "$CLT/usr/bin/swift-frontend" -nt "$SHIM/usr/bin/swift-frontend" ]; then
        echo "Command Line Tools updated since the shadow toolchain was built; rebuilding it…"
        rm -rf "$SHIM"
    fi
    if [ ! -x "$SHIM/usr/bin/swiftc" ]; then
        echo "Setting up shadow toolchain (CLT has duplicate SwiftBridging modulemap)…"
        rm -rf "$SHIM"; mkdir -p "$SHIM/usr/bin" "$SHIM/usr/include/swift"
        cp "$CLT/usr/bin/swift-frontend" "$CLT/usr/bin/swift-driver" "$SHIM/usr/bin/"
        for f in "$CLT/usr/bin/"*; do b=$(basename "$f"); [ -e "$SHIM/usr/bin/$b" ] || ln -s "$f" "$SHIM/usr/bin/$b"; done
        for l in swiftc swift; do rm -f "$SHIM/usr/bin/$l"; ln -s swift-frontend "$SHIM/usr/bin/$l"; done
        for d in lib libexec share local; do [ -e "$CLT/usr/$d" ] && ln -s "$CLT/usr/$d" "$SHIM/usr/$d"; done
        for f in "$CLT/usr/include/"*; do b=$(basename "$f"); [ "$b" = "swift" ] || ln -s "$f" "$SHIM/usr/include/$b"; done
        ln -s "$CLT/usr/include/swift/bridging" "$SHIM/usr/include/swift/bridging"
        ln -s "$CLT/usr/include/swift/bridging.modulemap" "$SHIM/usr/include/swift/bridging.modulemap"
    fi
    SWIFTC="$SHIM/usr/bin/swiftc"
fi

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"

echo "Compiling app…"
"$SWIFTC" -O -parse-as-library -target "$TARGET" -sdk "$SDK" \
    Shared/*.swift App/*.swift \
    -o "$APP/Contents/MacOS/ClaudeUsage"

echo "Compiling widget extension…"
# App extensions must enter through NSExtensionMain, not the normal Swift main:
# WidgetKit's XPC host bootstraps from there and finds the @main WidgetBundle
# via its protocol conformance. Without this the process launches and dies
# ("Unrecognized extension type"), and chronod reports "Launch failed."
"$SWIFTC" -O -parse-as-library -application-extension -target "$TARGET" -sdk "$SDK" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    Shared/*.swift Widget/*.swift \
    -o "$APPEX/Contents/MacOS/ClaudeUsageWidget"

cp Support/App-Info.plist "$APP/Contents/Info.plist"
cp Support/Widget-Info.plist "$APPEX/Contents/Info.plist"
if [ -f Support/AppIcon.icns ]; then
    cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

echo "Signing…"
codesign --force --sign - --identifier com.swarnim.ClaudeCodeUsage.Widget \
    --entitlements Support/Widget.entitlements "$APPEX"
codesign --force --sign - --identifier com.swarnim.ClaudeCodeUsage "$APP"

echo "Built $APP"
