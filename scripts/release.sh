#!/bin/bash
# Nook release pipeline: archive → Developer ID export → notarize → staple →
# DMG → notarize DMG → staple → Sparkle appcast.
#
# One-time setup lives in docs/RELEASE.md (Developer ID cert, notarytool
# credentials profile, Sparkle EdDSA keys, appcast hosting).
#
# Usage:
#   scripts/release.sh              # full pipeline
#   SKIP_NOTARIZE=1 scripts/release.sh   # local smoke run (no cert/creds needed past export)
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
BUILD_DIR="$REPO_ROOT/build/release"
RELEASES_DIR="$REPO_ROOT/build/releases"   # generate_appcast scans this dir
NOTARY_PROFILE="${NOTARY_PROFILE:-nook-notary}"

# macOS 27 SDK lives in the beta Xcode on the dev machine; CI xcode-selects
# its own, so only default when the beta install is actually present.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
[[ -n "$VERSION" ]] || { echo "error: MARKETING_VERSION not found in project.yml" >&2; exit 1; }
echo "==> Releasing Nook $VERSION"

echo "==> Generating project"
xcodegen generate

echo "==> Archiving (Release)"
rm -rf "$BUILD_DIR"
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release \
    -archivePath "$BUILD_DIR/Nook.xcarchive" \
    -destination 'generic/platform=macOS' \
    archive | tail -20

echo "==> Exporting with Developer ID signing"
xcodebuild -exportArchive \
    -archivePath "$BUILD_DIR/Nook.xcarchive" \
    -exportOptionsPlist scripts/ExportOptions.plist \
    -exportPath "$BUILD_DIR/export" | tail -10

APP="$BUILD_DIR/export/Nook.app"
codesign --verify --deep --strict "$APP"
echo "==> Signature OK: $(codesign -dvv "$APP" 2>&1 | grep '^Authority' | head -1)"

if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
    echo "==> Notarizing app"
    ditto -c -k --keepParent "$APP" "$BUILD_DIR/Nook.zip"
    xcrun notarytool submit "$BUILD_DIR/Nook.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
fi

echo "==> Building DMG"
DMG="$RELEASES_DIR/Nook-$VERSION.dmg"
mkdir -p "$RELEASES_DIR"
rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Nook" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
    echo "==> Notarizing DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl -a -t open --context context:primary-signature -v "$DMG" || true
fi

echo "==> Generating Sparkle appcast"
# generate_appcast ships in the Sparkle SPM artifact bundle; find it in DerivedData.
# Prefer the repo-local SPM artifacts (this build's own checkout) over a glob
# across the shared user DerivedData — anything on this machine can write to
# ~/Library/Developer/Xcode/DerivedData, and this binary gets handed the
# update-signing key. (The tool is ad-hoc signed upstream, so a Team ID pin
# isn't possible; path trust is the available control.)
GENERATE_APPCAST="$REPO_ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [[ ! -x "$GENERATE_APPCAST" ]]; then
    GENERATE_APPCAST=$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/*/Sparkle/bin/generate_appcast' -print -quit 2>/dev/null || true)
    [[ -n "$GENERATE_APPCAST" ]] && echo "warning: using generate_appcast from shared DerivedData: $GENERATE_APPCAST" >&2
fi
if [[ -n "$GENERATE_APPCAST" ]]; then
    # Signs with the EdDSA private key from the keychain (generate_keys), or
    # from a file when SPARKLE_KEY_FILE is set (CI).
    APPCAST_ARGS=(--download-url-prefix "https://github.com/fif7y/nook/releases/download/v$VERSION/")
    [[ -n "${SPARKLE_KEY_FILE:-}" ]] && APPCAST_ARGS+=(--ed-key-file "$SPARKLE_KEY_FILE")
    "$GENERATE_APPCAST" "${APPCAST_ARGS[@]}" "$RELEASES_DIR"
    # generate_appcast stamps EVERY entry with the current release's
    # download-url-prefix, pointing prior versions' DMGs at a tag that
    # doesn't host them (404 for anyone updating from further back).
    # Re-point each Nook-X.Y.Z.dmg at its own vX.Y.Z tag.
    perl -pi -e 's#(releases/download/)v[\d.]+/(Nook-([\d.]+)\.dmg)#$1v$3/$2#g' \
        "$RELEASES_DIR/appcast.xml"
    echo "==> Appcast written to $RELEASES_DIR/appcast.xml (prior-version URLs re-pointed)"
else
    echo "warning: generate_appcast not found in DerivedData — build the app once so SPM fetches Sparkle, or download the Sparkle release tools" >&2
fi

echo ""
echo "Done. Artifacts:"
echo "  app:     $APP"
echo "  dmg:     $DMG"
echo "  appcast: $RELEASES_DIR/appcast.xml"
echo ""
echo "Next: create GitHub release v$VERSION with the DMG attached, then publish"
echo "appcast.xml to the appcast host (see docs/RELEASE.md)."
