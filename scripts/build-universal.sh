#!/usr/bin/env bash
#
# Builds a universal (arm64 + x86_64) Release .app bundle.
#
# Usage:
#   scripts/build-universal.sh
#
# The output is copied to: dist/VoiceBooks.app
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

export PATH="/usr/local/bin:$PATH"

CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"
APP_NAME="VoiceBooks"

echo "==> Building $APP_NAME ($CONFIGURATION, arm64 + x86_64)"
xcodebuild \
    -project VoiceBooks.xcodeproj \
    -scheme VoiceBooks \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "Error: build product not found at $BUILT_APP" >&2
    exit 1
fi

echo "==> Copying to $DIST_DIR"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
ditto "$BUILT_APP" "$DIST_DIR/$APP_NAME.app"

# The upstream onnxruntime xcframework ships malformed self-referential
# symlinks (e.g. `Versions/A/A -> A`). They break `codesign --deep` with
# "Too many levels of symbolic links", so strip them and re-sign (ad-hoc).
echo "==> Sanitizing embedded framework symlinks"
find "$DIST_DIR/$APP_NAME.app/Contents/Frameworks" -type l 2>/dev/null | while IFS= read -r link; do
    name="$(basename "$link")"
    target="$(readlink "$link" 2>/dev/null || true)"
    parent="$(basename "$(dirname "$link")")"
    if [[ "$target" == "$name" || "$parent" == "$name" ]]; then
        rm -f "$link"
    fi
done

echo "==> Re-signing (ad-hoc, to match the pruned bundle)"
codesign --force --deep --sign - "$DIST_DIR/$APP_NAME.app"

echo "==> Verifying signature"
codesign --verify --deep --strict "$DIST_DIR/$APP_NAME.app"

echo "==> Verifying architectures"
lipo -info "$DIST_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME"

echo ""
echo "Done: $DIST_DIR/$APP_NAME.app"
