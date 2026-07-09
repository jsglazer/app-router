#!/bin/bash
#
# make-dmg.sh — build app-router, wrap it in a proper .app bundle, sign it, and
# package a drag-to-Applications DMG. One command; no third-party tools (uses
# swift, codesign, hdiutil, and xcrun — all built into macOS + Xcode).
#
# A real .app bundle (not the bare binary) is what lets macOS deliver Finder/
# browser open events to app-router and lets it register as a default handler.
#
# The signing tier adapts to what's in your keychain:
#   • "Developer ID Application" identity present  -> hardened-runtime signed
#       + a notarytool profile (default: app-router-notary) present
#                                                  -> notarized & stapled (best)
#   • neither                                      -> ad-hoc signed (local use)
#
# Override detection:
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   pin the identity
#   NOTARY_PROFILE="app-router-notary"                        notarytool profile
#   SKIP_NOTARIZE=1                                           sign but don't notarize
#   SKIP_SIGN=1                                               no code signing: ad-hoc
#       only (skip Developer ID + notarization entirely). Ad-hoc is the minimum a
#       Mach-O needs to launch on Apple Silicon; the result is for local use only.
#
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

APP_NAME="app-router"
INFO_PLIST="Sources/AppRouter/Info.plist"
ICNS="Resources/AppIcon.icns"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"
mkdir -p "$DIST"

echo "==> app-router packager (version $VERSION)"

# 1. Build the release binary.
echo "==> swift build -c release"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
[ -x "$BIN" ] || { echo "no binary at $BIN" >&2; exit 1; }

# 1b. Generate the icon once if it isn't checked in yet.
if [ ! -f "$ICNS" ]; then
    echo "==> $ICNS missing; generating"
    Scripts/make-icon.sh
fi

# 2. Assemble the .app bundle.
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN"        "$APP/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
cp "$ICNS"       "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 3. Resolve a signing identity (auto-detect a Developer ID unless pinned or disabled).
if [ -n "${SKIP_SIGN:-}" ]; then
    # Explicit "no code signing": force the ad-hoc path even when a Developer ID is
    # in the keychain, and skip notarization outright (step 4 requires a real signature).
    echo "==> SKIP_SIGN set — no Developer ID signing, no notarization (ad-hoc, local use)"
    SIGN_IDENTITY=""
elif [ -z "${SIGN_IDENTITY:-}" ]; then
    # `|| true`: grep/head exiting non-zero (no Developer ID present, or SIGPIPE
    # from head closing early) must not trip `set -o pipefail` and abort the run.
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | grep 'Developer ID Application' | head -1 \
        | sed -E 's/.*"(.*)".*/\1/' || true)"
fi

if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "==> signing (hardened runtime): $SIGN_IDENTITY"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
    SIGNED_REAL=1
else
    echo "==> no Developer ID identity; ad-hoc signing (local use only)"
    codesign --force --sign - "$APP"
    SIGNED_REAL=0
fi
codesign --verify --strict --verbose=2 "$APP"

# 4. Notarize — only when Developer-ID-signed and a notary profile exists.
NOTARY_PROFILE="${NOTARY_PROFILE:-app-router-notary}"
NOTARIZED=0
# Authoritatively test the profile via notarytool itself — recent Xcode stores the
# credential where `security find-generic-password` can't reliably see it, so probe
# by using it (a lightweight authenticated call) rather than grepping the keychain.
have_profile() {
    xcrun notarytool history --keychain-profile "$1" >/dev/null 2>&1
}
if [ "$SIGNED_REAL" = 1 ] && [ -z "${SKIP_NOTARIZE:-}" ] \
   && [ -n "$NOTARY_PROFILE" ] && have_profile "$NOTARY_PROFILE"; then
    echo "==> notarizing via profile '$NOTARY_PROFILE' (submits to Apple, waits)"
    ZIP="$DIST/$APP_NAME-notarize.zip"
    /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    NOTARIZED=1
elif [ "$SIGNED_REAL" = 1 ]; then
    echo "==> skipping notarization (no notary profile '$NOTARY_PROFILE')"
fi

# 5. Build the drag-to-Applications DMG.
echo "==> building DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# 6. Notarize + staple the DMG itself. The app inside is already notarized+stapled
#    (step 4), so the extracted app validates offline; notarizing the DMG (its own
#    submission — a DMG needs its own ticket, it is not covered by the app's) makes
#    the downloaded disk image pass Gatekeeper before it is even mounted.
if [ "$NOTARIZED" = 1 ]; then
    echo "==> notarizing the DMG (submits to Apple, waits)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo
echo "==> DONE"
echo "    App: $APP"
echo "    DMG: $DMG"
if [ "$NOTARIZED" = 1 ]; then
    echo "    Signing: Developer ID + notarized + stapled (clean double-click install)"
elif [ "$SIGNED_REAL" = 1 ]; then
    echo "    Signing: Developer ID, NOT notarized (Gatekeeper still warns off-machine)"
else
    echo "    Signing: ad-hoc (first launch on another Mac: right-click ▸ Open)"
fi
