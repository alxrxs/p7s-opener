#!/bin/bash
# Builds "build/P7S Opener.app". Pass "install" to also copy it to /Applications and register it.
#   CODESIGN_IDENTITY=-          force an ad-hoc signature (what the Homebrew formula uses)
#   SWIFT_BUILD_FLAGS=...        extra flags for swift build (e.g. --disable-sandbox under brew)
#
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC2086
swift build -c release ${SWIFT_BUILD_FLAGS:-}

APP="build/P7S Opener.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/P7SOpener "$APP/Contents/MacOS/P7SOpener"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Version comes from the latest vX.Y.Z tag (falling back to Info.plist); the build
# number is the commit count, so every build from a newer commit sorts higher.
PLIST="$APP/Contents/Info.plist"
if TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null); then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${TAG#v}" "$PLIST"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" "$PLIST"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')}"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc identity})"

if [[ "${1:-}" == "install" ]]; then
    DEST="/Applications/P7S Opener.app"
    pkill -x P7SOpener || true
    for _ in {1..50}; do pgrep -x P7SOpener >/dev/null || break; sleep 0.1; done
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    # Register with Launch Services so double-clicking a .p7s / .p7m opens it.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    echo "Installed to $DEST"
fi
