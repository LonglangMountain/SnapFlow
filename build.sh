#!/bin/bash
# Build SnapFlow and assemble a runnable .app bundle.
#
# Usage:
#   ./build.sh                    # debug build (host arch, fast)
#   ./build.sh release            # release build (host arch)
#   ./build.sh release universal  # release + universal (arm64 + x86_64)
#
# The resulting bundle is written to ./SnapFlow.app
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP_NAME="SnapFlow"
BUNDLE="${APP_NAME}.app"

# Universal binary (Intel + Apple Silicon) when requested, or automatically for
# release builds so the shipped app runs on older Intel Macs too.
ARCH_FLAGS=""
if [ "${2:-}" = "universal" ] || [ "$CONFIG" = "release" ]; then
    ARCH_FLAGS="--arch arm64 --arch x86_64"
fi

echo "==> swift build ($CONFIG${ARCH_FLAGS:+, universal})"
swift build -c "$CONFIG" $ARCH_FLAGS

BIN_PATH="$(swift build -c "$CONFIG" $ARCH_FLAGS --show-bin-path)"

echo "==> Assembling ${BUNDLE}"
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp "${BIN_PATH}/${APP_NAME}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${BUNDLE}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${BUNDLE}/Contents/Resources/AppIcon.icns"

# Prefer a stable self-signed identity (see setup-signing.sh) so TCC keeps the
# screen-recording grant across rebuilds. Fall back to ad-hoc if it's absent.
SIGN_NAME="SnapFlow Local"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_NAME"; then
    SIGN_ID="$SIGN_NAME"
    echo "==> Code signing with '$SIGN_NAME'"
else
    SIGN_ID="-"
    echo "==> Ad-hoc code signing (run ./setup-signing.sh once for a stable identity)"
fi
codesign --force --deep --sign "$SIGN_ID" "$BUNDLE"

echo "==> Done: ${PWD}/${BUNDLE}"
echo "    Launch with: open ${BUNDLE}"

# Release builds also produce distributable archives with STABLE names (no
# version in the filename) so the website can link to a permanent URL:
#   https://github.com/<owner>/<repo>/releases/latest/download/SnapFlow.dmg
# Upload these exact files as the release assets each version and the download
# links never need to change.
if [ "$CONFIG" = "release" ]; then
    echo "==> Packaging dist/SnapFlow.zip and dist/SnapFlow.dmg"
    rm -rf dist
    mkdir -p dist
    ditto -c -k --keepParent "$BUNDLE" "dist/${APP_NAME}.zip"

    # Build a "drag to Applications" installer DMG: stage the app next to an
    # /Applications symlink, lay the window out with Finder, then compress.
    STAGE="dist/dmg-stage"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp -R "$BUNDLE" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"

    RW_DMG="dist/${APP_NAME}-rw.dmg"
    hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" \
        -fs HFS+ -format UDRW -ov "$RW_DMG"

    # Detach any stale volume of the same name first, so our image mounts under
    # the exact expected name (otherwise it becomes "SnapFlow 1" and the Finder
    # layout below targets the wrong disk and fails with -10006).
    for v in /Volumes/"${APP_NAME}"*; do
        [ -d "$v" ] && hdiutil detach "$v" -force -quiet 2>/dev/null || true
    done

    ATTACH="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
    DEV="$(echo "$ATTACH" | awk '/^\/dev\// {print $1; exit}')"
    MOUNT="$(echo "$ATTACH" | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p' | tail -1)"
    VOL="$(basename "$MOUNT")"

    # Window layout is cosmetic — never fail the build if Finder automation is
    # unavailable (headless/CI); the Applications symlink alone enables install.
    osascript <<EOF || echo "    (skipped Finder layout)"
tell application "Finder"
  tell disk "${VOL}"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 150, 740, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set position of item "${APP_NAME}.app" of container window to {150, 190}
    set position of item "Applications" of container window to {400, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

    sync
    hdiutil detach "$DEV" -quiet || hdiutil detach "$MOUNT" -force -quiet || true
    hdiutil convert "$RW_DMG" -quiet -format UDZO -imagekey zlib-level=9 \
        -ov -o "dist/${APP_NAME}.dmg"
    rm -f "$RW_DMG"
    rm -rf "$STAGE"

    echo "    dist/${APP_NAME}.zip"
    echo "    dist/${APP_NAME}.dmg"
fi
