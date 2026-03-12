#!/bin/bash

set -euo pipefail

APP_NAME="${APP_NAME:-VoiceMemo}"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="${BUILD_DIR:-.build/$CONFIGURATION}"
SOURCE_INFO_PLIST="${SOURCE_INFO_PLIST:-Sources/VoiceMemo/Info.plist}"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-VoiceMemo.entitlements}"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARIZE="${NOTARIZE:-false}"
SWIFT_BUILD_EXTRA_ARGS="${SWIFT_BUILD_EXTRA_ARGS:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"

APP_BUNDLE_NAME="$APP_NAME.app"
APP_BUNDLE="$OUTPUT_DIR/$APP_BUNDLE_NAME"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST_PATH="$CONTENTS_DIR/Info.plist"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

is_true() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

plist_get() {
    local plist_path="$1"
    local key="$2"
    "$PLIST_BUDDY" -c "Print :$key" "$plist_path" 2>/dev/null || true
}

plist_set() {
    local plist_path="$1"
    local key="$2"
    local value_type="$3"
    local value="$4"

    if "$PLIST_BUDDY" -c "Print :$key" "$plist_path" >/dev/null 2>&1; then
        "$PLIST_BUDDY" -c "Set :$key $value" "$plist_path"
    else
        "$PLIST_BUDDY" -c "Add :$key $value_type $value" "$plist_path"
    fi
}

create_zip() {
    local source_path="$1"
    local output_path="$2"

    rm -f "$output_path"
    ditto -c -k --sequesterRsrc --keepParent "$source_path" "$output_path"
}

require_command swift
require_command codesign
require_command ditto
require_command shasum
require_command "$PLIST_BUDDY"

DEFAULT_VERSION="$(plist_get "$SOURCE_INFO_PLIST" CFBundleShortVersionString)"
APP_VERSION="${APP_VERSION:-${DEFAULT_VERSION:-1.0.0}}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCHIVE_NAME="${ARCHIVE_NAME:-$APP_NAME-$APP_VERSION-macos.zip}"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"
NOTARY_ARCHIVE_PATH="$OUTPUT_DIR/$APP_NAME-$APP_VERSION-notary.zip"
SWIFT_BUILD_ARGS=(-c "$CONFIGURATION")

if [ -n "$SWIFT_BUILD_EXTRA_ARGS" ]; then
    # Split additional flags from the environment for CI/local overrides.
    # shellcheck disable=SC2206
    EXTRA_BUILD_ARGS=($SWIFT_BUILD_EXTRA_ARGS)
    SWIFT_BUILD_ARGS+=("${EXTRA_BUILD_ARGS[@]}")
fi

echo "Step 1: Building project in $CONFIGURATION mode..."
swift build "${SWIFT_BUILD_ARGS[@]}"

echo "Step 2: Preparing app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "Step 3: Copying binary, Info.plist and resources..."
cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/"
cp "$SOURCE_INFO_PLIST" "$INFO_PLIST_PATH"
if [ -f "Sources/VoiceMemo/Resources/AppIcon.icns" ]; then
    cp "Sources/VoiceMemo/Resources/AppIcon.icns" "$RESOURCES_DIR/"
fi

echo "Step 4: Injecting bundle version metadata..."
plist_set "$INFO_PLIST_PATH" CFBundleShortVersionString string "$APP_VERSION"
plist_set "$INFO_PLIST_PATH" CFBundleVersion string "$BUILD_NUMBER"

echo "Step 5: Signing application bundle..."
CODE_SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [ -f "$ENTITLEMENTS_PATH" ]; then
    CODE_SIGN_ARGS+=(--entitlements "$ENTITLEMENTS_PATH")
fi
if [ "$SIGN_IDENTITY" != "-" ]; then
    CODE_SIGN_ARGS+=(--timestamp --options runtime)
fi
codesign "${CODE_SIGN_ARGS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

if is_true "$NOTARIZE"; then
    if [ "$SIGN_IDENTITY" = "-" ]; then
        echo "Notarization requires a non ad-hoc signing identity." >&2
        exit 1
    fi
    if [ -z "$APPLE_ID" ] || [ -z "$APPLE_APP_SPECIFIC_PASSWORD" ] || [ -z "$APPLE_TEAM_ID" ]; then
        echo "Notarization requires APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD and APPLE_TEAM_ID." >&2
        exit 1
    fi

    require_command xcrun

    echo "Step 6: Creating notarization archive..."
    create_zip "$APP_BUNDLE" "$NOTARY_ARCHIVE_PATH"

    echo "Step 7: Submitting archive for notarization..."
    xcrun notarytool submit "$NOTARY_ARCHIVE_PATH" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait

    echo "Step 8: Stapling notarization ticket..."
    xcrun stapler staple "$APP_BUNDLE"
    spctl -a -vvv --type exec "$APP_BUNDLE"

    rm -f "$NOTARY_ARCHIVE_PATH"
fi

echo "Step 9: Creating distributable archive..."
mkdir -p "$OUTPUT_DIR"
create_zip "$APP_BUNDLE" "$ARCHIVE_PATH"
shasum -a 256 "$ARCHIVE_PATH" > "$CHECKSUM_PATH"

echo "------------------------------------------------"
echo "App bundle: $APP_BUNDLE"
echo "Archive:    $ARCHIVE_PATH"
echo "SHA256:     $CHECKSUM_PATH"
echo "Version:    $APP_VERSION ($BUILD_NUMBER)"
echo "Signing:    $SIGN_IDENTITY"
if is_true "$NOTARIZE"; then
    echo "Notarized:  yes"
else
    echo "Notarized:  no"
fi
echo "------------------------------------------------"
