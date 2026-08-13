#!/usr/bin/env bash
#
# Assembles Baton.app. SwiftPM builds a bare executable, and macOS needs a real
# bundle for notifications, for the menu bar item, and for a stable bundle id.
#
# Usage:
#   scripts/build-app.sh              Debug build into ./dist
#   scripts/build-app.sh release      Release build
#
# Signing:
#   BATON_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#
# An ad-hoc signature is enough to run locally. Notification delivery is only
# reliable with a real Developer ID signature, so set the variable before you
# rely on banners.

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Baton.app"
RESOURCES="$ROOT/Sources/BatonApp/Resources"

# The version in Info.plist is the single source of truth for a release.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RESOURCES/Info.plist")"

cd "$ROOT"

echo "==> Building Baton $VERSION ($CONFIG)"
swift build -c "$CONFIG" --product BatonApp
swift build -c "$CONFIG" --product baton-mcp

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Icon"
if [ ! -f "$DIST/Baton.icns" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$DIST/Baton.icns" ]; then
	mkdir -p "$DIST"
	swift "$ROOT/scripts/make-icon.swift" >/dev/null
	echo "    rendered dist/Baton.icns"
else
	echo "    up to date"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/BatonApp" "$APP/Contents/MacOS/BatonApp"
# Ship the CLI inside the bundle. One install, one place to point an agent at.
cp "$BIN_DIR/baton-mcp" "$APP/Contents/MacOS/baton-mcp"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"
cp "$DIST/Baton.icns" "$APP/Contents/Resources/Baton.icns"

# SwiftPM emits a resource bundle when a target has resources. Copy any that exist.
for bundle in "$BIN_DIR"/*.bundle; do
	[ -e "$bundle" ] || continue
	cp -R "$bundle" "$APP/Contents/Resources/"
done

echo "==> Signing"
IDENTITY="${BATON_SIGN_IDENTITY:-}"
if [ -n "$IDENTITY" ]; then
	# Only a Developer ID may claim the Time Sensitive entitlement. It is
	# restricted, and launchd refuses to spawn a binary that claims it without a
	# matching provisioning profile.
	SIGN_ARGS=(--force --deep --options runtime --timestamp --sign "$IDENTITY")
	case "$IDENTITY" in
	*"Developer ID"*)
		SIGN_ARGS+=(--entitlements "$RESOURCES/Baton.entitlements")
		;;
	*)
		echo "    '$IDENTITY' is not a Developer ID, so skipping restricted entitlements"
		;;
	esac
	codesign "${SIGN_ARGS[@]}" "$APP"
	echo "    signed with: $IDENTITY"
else
	# Ad-hoc, and deliberately with no entitlements file.
	# `usernotifications.time-sensitive` is a restricted entitlement. launchd
	# refuses to spawn an ad-hoc binary that claims it, so a local build has to
	# go without. Urgent tasks then post a normal banner instead of breaking
	# through Focus.
	codesign --force --deep --sign - "$APP"
	echo "    signed ad-hoc, no entitlements"
	echo "    set BATON_SIGN_IDENTITY for reliable notifications and Time Sensitive alerts"
fi

# Register the bundle id so `open -b dev.baton.Baton` works from the MCP binary.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
	-f "$APP" 2>/dev/null || true

echo
echo "Built: $APP"
echo "MCP:   $APP/Contents/MacOS/baton-mcp"
echo
echo "Next:"
echo "  open $APP"
echo "  scripts/install-mcp.sh          # print the agent config"
