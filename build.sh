#!/bin/zsh
set -eu
cd "${0:A:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
mkdir -p .build/universal
for arch in arm64 x86_64; do
    xcrun swiftc -swift-version 5 -O -target "$arch-apple-macosx14.0" \
        -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
        -module-name iPadLANDisplay Sources/*.swift -o ".build/universal/$arch"
done
APP="$PWD/dist/iPad LAN Display.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/universal/arm64 .build/universal/x86_64 -output "$APP/Contents/MacOS/iPadLANDisplay"
cp Web/index.html "$APP/Contents/Resources/index.html"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleExecutable</key><string>iPadLANDisplay</string><key>CFBundleIdentifier</key><string>local.svx.ipadlandisplay</string><key>CFBundleName</key><string>iPad LAN Display</string><key>CFBundleVersion</key><string>9</string><key>CFBundleShortVersionString</key><string>0.3.1</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/><key>NSLocalNetworkUsageDescription</key><string>Передача экрана на ваш iPad по локальной сети.</string><key>NSScreenCaptureUsageDescription</key><string>Захват выбранного экрана для передачи на iPad.</string></dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign "${IPAD_DISPLAY_SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "$APP"
