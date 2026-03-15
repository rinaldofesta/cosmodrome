#!/bin/bash
# Build Cosmodrome.app bundle
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Cosmodrome"
BUNDLE_DIR="$PROJ_DIR/build/${APP_NAME}.app"
CONTENTS="$BUNDLE_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# Clean previous bundle
rm -rf "$BUNDLE_DIR"

# Always rebuild release
echo "Building release..."
cd "$PROJ_DIR" && swift build -c release

# Create bundle structure
mkdir -p "$MACOS" "$RESOURCES"

# Copy binaries
cp "$PROJ_DIR/.build/release/CosmodromeApp" "$MACOS/Cosmodrome"
cp "$PROJ_DIR/.build/release/CosmodromeHook" "$MACOS/CosmodromeHook"
if [ -f "$PROJ_DIR/.build/release/CosmodromeCLI" ]; then
    cp "$PROJ_DIR/.build/release/CosmodromeCLI" "$MACOS/cosmoctl"
fi

# Create Info.plist
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Cosmodrome</string>
    <key>CFBundleDisplayName</key>
    <string>Cosmodrome</string>
    <key>CFBundleIdentifier</key>
    <string>com.cosmodrome.terminal</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>Cosmodrome</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Cosmodrome. All rights reserved.</string>
</dict>
</plist>
PLIST

# Copy theme files
if [ -d "$PROJ_DIR/Resources/Themes" ]; then
    cp -r "$PROJ_DIR/Resources/Themes" "$RESOURCES/Themes"
fi

# Copy default config
if [ -f "$PROJ_DIR/Resources/DefaultConfig.yml" ]; then
    cp "$PROJ_DIR/Resources/DefaultConfig.yml" "$RESOURCES/DefaultConfig.yml"
fi

# Generate .icns from master icon (Resources/AppIcon_1024.png)
MASTER_ICON="$PROJ_DIR/Resources/AppIcon_1024.png"
ICONSET_DIR="$PROJ_DIR/build/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

if [ -f "$MASTER_ICON" ]; then
    echo "Generating icon sizes from master..."
    sips -z 16 16     "$MASTER_ICON" --out "$ICONSET_DIR/icon_16x16.png"      > /dev/null
    sips -z 32 32     "$MASTER_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png"   > /dev/null
    sips -z 32 32     "$MASTER_ICON" --out "$ICONSET_DIR/icon_32x32.png"      > /dev/null
    sips -z 64 64     "$MASTER_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png"   > /dev/null
    sips -z 128 128   "$MASTER_ICON" --out "$ICONSET_DIR/icon_128x128.png"    > /dev/null
    sips -z 256 256   "$MASTER_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
    sips -z 256 256   "$MASTER_ICON" --out "$ICONSET_DIR/icon_256x256.png"    > /dev/null
    sips -z 512 512   "$MASTER_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
    sips -z 512 512   "$MASTER_ICON" --out "$ICONSET_DIR/icon_512x512.png"    > /dev/null
    cp "$MASTER_ICON"                       "$ICONSET_DIR/icon_512x512@2x.png"
    echo "All icon sizes generated"
else
    echo "Warning: Master icon not found at $MASTER_ICON — app will have no icon"
fi

# Convert iconset to icns
if [ -f "$ICONSET_DIR/icon_512x512@2x.png" ]; then
    if iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES/AppIcon.icns" 2>&1; then
        echo "Icon converted to .icns"
    else
        echo "Warning: iconutil failed"
    fi
fi
rm -rf "$ICONSET_DIR"

echo ""
echo "✅ Built: $BUNDLE_DIR"
echo ""
echo "To install, run:"
echo "  cp -r \"$BUNDLE_DIR\" /Applications/"
echo ""
echo "Then launch Cosmodrome from Spotlight (Cmd+Space → Cosmodrome) or /Applications."
