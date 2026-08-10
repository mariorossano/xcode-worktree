#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="$PROJECT_ROOT/dist/Xcode Worktree.app"
EXPECTED_BUNDLE_ID="dev.xcodeworktree.app"
EXPECTED_BUNDLE_NAME="Xcode Worktree"
EXPECTED_EXECUTABLE="XcodeWorktree"
ICON_FILE="XcodeWorktree.icns"
ICON_SOURCE="$PROJECT_ROOT/Resources/$ICON_FILE"

remove_product_app() {
    local path="$1"
    [[ -e "$path" ]] || return 0

    if [[ ! -d "$path" ]]; then
        echo "Refusing to replace non-directory path: $path" >&2
        exit 1
    fi

    local bundle_name
    local executable
    bundle_name="$(plutil -extract CFBundleName raw "$path/Contents/Info.plist" 2>/dev/null || true)"
    executable="$(plutil -extract CFBundleExecutable raw "$path/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$bundle_name" != "$EXPECTED_BUNDLE_NAME" \
        || "$executable" != "$EXPECTED_EXECUTABLE" ]]; then
        echo "Refusing to replace an app not built by Xcode Worktree: $path" >&2
        exit 1
    fi

    rm -r "$path"
}

cd "$PROJECT_ROOT"
swift build -c release --product XcodeWorktreeApp

if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "Missing app icon: $ICON_SOURCE" >&2
    exit 1
fi

remove_product_app "$APP_PATH"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$PROJECT_ROOT/.build/release/XcodeWorktreeApp" "$APP_PATH/Contents/MacOS/XcodeWorktree"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$ICON_SOURCE" "$APP_PATH/Contents/Resources/$ICON_FILE"

bundle_id="$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "Unexpected CFBundleIdentifier in built app: $bundle_id" >&2
    exit 1
fi

bundle_icon="$(plutil -extract CFBundleIconFile raw "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$bundle_icon" != "$ICON_FILE" ]]; then
    echo "Unexpected CFBundleIconFile in built app: $bundle_icon" >&2
    exit 1
fi

codesign --force --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

echo "Built $APP_PATH with an ad-hoc signature"
