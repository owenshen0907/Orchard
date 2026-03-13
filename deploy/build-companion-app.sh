#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-OrchardCompanion}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-OrchardCompanionApp}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.owen.orchard.companion}"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_VERSION="${BUILD_VERSION:-$(date +%Y%m%d%H%M%S)}"
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-14.0}"

STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_PATH="$REPO_ROOT/.build/companion-archive-$STAMP.xcarchive"
DIST_ROOT="$REPO_ROOT/.build/dist/companion-$STAMP"
APP_PATH="$DIST_ROOT/$APP_NAME.app"
ZIP_PATH="$DIST_ROOT/$APP_NAME.zip"
BIN_SOURCE="$ARCHIVE_PATH/Products/usr/local/bin/$EXECUTABLE_NAME"

mkdir -p "$DIST_ROOT"

echo "Archiving $EXECUTABLE_NAME ..."
xcodebuild \
    -scheme "$EXECUTABLE_NAME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS" \
    archive \
    -archivePath "$ARCHIVE_PATH"

if [[ ! -x "$BIN_SOURCE" ]]; then
    echo "Expected binary not found at $BIN_SOURCE" >&2
    exit 1
fi

echo "Packaging .app bundle ..."
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_SOURCE" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
chmod 755 "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

cat >"$APP_PATH/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$MARKETING_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MINIMUM_SYSTEM_VERSION</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

printf 'APPL????' >"$APP_PATH/Contents/PkgInfo"

echo "Signing .app bundle ..."
codesign --force --deep --sign - "$APP_PATH"

echo "Compressing artifact ..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo
echo "Done."
echo "App bundle: $APP_PATH"
echo "Zip archive: $ZIP_PATH"
