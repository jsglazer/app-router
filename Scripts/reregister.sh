#!/bin/bash
#
# reregister.sh — rebuild app-router, reinstall it, and re-register the bundle
# with LaunchServices so newly declared document types / exported UTIs (e.g.
# ones added by plistaddreg.py) actually take effect.
#
# LaunchServices only reads the Info.plist embedded *inside the installed .app
# bundle*, so editing Sources/AppRouter/Info.plist alone does nothing until the
# bundle is rebuilt, reinstalled, and re-registered. This bundles those steps.
#
# Usage:
#   Scripts/reregister.sh              # full rebuild (make-dmg.sh) -> install to
#                                      #   /Applications -> re-register -> relaunch
#   Scripts/reregister.sh --quick      # skip swift rebuild; just refresh the
#                                      #   bundle's Info.plist from source, then
#                                      #   reinstall + re-register + relaunch
#   Scripts/reregister.sh --dist       # register/run dist/app-router.app in place
#                                      #   (don't copy into /Applications)
#   Scripts/reregister.sh --rebuild-db # also force a full LaunchServices DB rebuild
#
# Flags may be combined, e.g.  Scripts/reregister.sh --quick --dist
#
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

APP_NAME="app-router"
BUNDLE_ID="com.jsglazer.app-router"
INFO_PLIST="Sources/AppRouter/Info.plist"
DIST_APP="$ROOT/dist/$APP_NAME.app"
INSTALL_APP="/Applications/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

QUICK=0        # --quick : skip the swift rebuild
USE_DIST=0     # --dist  : register/run from dist/ instead of /Applications
REBUILD_DB=0   # --rebuild-db : also kill+rebuild the whole LaunchServices DB

for arg in "$@"; do
    case "$arg" in
        --quick)      QUICK=1 ;;
        --dist)       USE_DIST=1 ;;
        --rebuild-db) REBUILD_DB=1 ;;
        -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# 1. Refresh the bundle so it carries the current Info.plist.
if [ "$QUICK" -eq 1 ]; then
    echo "▶ [quick] refreshing $DIST_APP/Contents/Info.plist from $INFO_PLIST"
    [ -d "$DIST_APP" ] || { echo "no bundle at $DIST_APP; run without --quick first" >&2; exit 1; }
    cp "$INFO_PLIST" "$DIST_APP/Contents/Info.plist"
else
    echo "▶ Step 1: Rebuild + repackage the .app bundle (Scripts/make-dmg.sh)..."
    Scripts/make-dmg.sh > /dev/null
fi

# 2. Decide which bundle we register/run, and install it there if needed.
if [ "$USE_DIST" -eq 1 ]; then
    TARGET_APP="$DIST_APP"
    echo "▶ Step 2: Using dist bundle in place ($TARGET_APP)"
else
    TARGET_APP="$INSTALL_APP"
    echo "▶ Step 2: Install the rebuilt app to /Applications..."
    rm -rf "$TARGET_APP"
    cp -R "$DIST_APP" "$TARGET_APP"
fi

# 3. Quit any running instance (menu-bar helper, LSUIElement).
echo "▶ Step 3: Quit the running instance..."
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || killall "$APP_NAME" 2>/dev/null || true
sleep 1

# 4. Re-register the target bundle so LaunchServices re-reads its declared types.
echo "▶ Step 4: Re-register with LaunchServices..."
"$LSREGISTER" -f "$TARGET_APP"

if [ "$REBUILD_DB" -eq 1 ]; then
    echo "▶ Step 4b: Forcing full LaunchServices database rebuild..."
    "$LSREGISTER" -kill -r -domain local -domain system -domain user
    "$LSREGISTER" -f "$TARGET_APP"
fi

# 5. Relaunch.
echo "▶ Step 5: Relaunch app-router..."
open "$TARGET_APP"

echo ""
echo "✓ Done! Declared types are now registered for $BUNDLE_ID."
echo ""
echo "Remember: declared types only become the *default* handler if they're also"
echo "in your config.jsonc (config extensions, nothing else):"
echo "  ~/.config/$APP_NAME/config.jsonc"
