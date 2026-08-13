#!/usr/bin/env bash
#
# Builds, signs, notarizes, and packages Baton for distribution.
#
# Usage:
#   scripts/release.sh                Full release from Info.plist version
#   scripts/release.sh --skip-notary  Build and package without notarizing
#
# Required for a real release:
#   BATON_SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   BATON_NOTARY_PROFILE  A notarytool keychain profile name
#
# Create the notary profile once:
#   xcrun notarytool store-credentials baton \
#     --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
#
# Why notarize: without it, Gatekeeper blocks the app on every other machine,
# and the user has to right-click to open. A menu bar tool that is hard to
# launch does not get used.

set -euo pipefail

SKIP_NOTARY=0
[ "${1:-}" = "--skip-notary" ] && SKIP_NOTARY=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Baton.app"
RESOURCES="$ROOT/Sources/BatonApp/Resources"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RESOURCES/Info.plist")"
DMG="$DIST/Baton-$VERSION.dmg"

cd "$ROOT"

if [ -z "${BATON_SIGN_IDENTITY:-}" ]; then
	echo "BATON_SIGN_IDENTITY is not set." >&2
	echo "A release needs a Developer ID. List yours with:" >&2
	echo "  security find-identity -v -p codesigning" >&2
	exit 1
fi

echo "==> Release build $VERSION"
scripts/build-app.sh release

echo "==> Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# Gatekeeper's own check. It fails before notarization, which is expected here.
spctl --assess --type execute --verbose "$APP" 2>&1 | sed 's/^/    /' || true

echo "==> Packaging $DMG"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# UDZO is the compressed read-only format Gatekeeper expects for an app DMG.
hdiutil create -volname "Baton $VERSION" \
	-srcfolder "$STAGE" \
	-ov -format UDZO \
	"$DMG" >/dev/null
rm -rf "$STAGE"

codesign --force --sign "$BATON_SIGN_IDENTITY" "$DMG"

if [ "$SKIP_NOTARY" = "1" ]; then
	echo "==> Skipping notarization"
else
	if [ -z "${BATON_NOTARY_PROFILE:-}" ]; then
		echo "BATON_NOTARY_PROFILE is not set. Run store-credentials first." >&2
		exit 1
	fi
	echo "==> Notarizing (this waits on Apple, usually a few minutes)"
	xcrun notarytool submit "$DMG" \
		--keychain-profile "$BATON_NOTARY_PROFILE" \
		--wait

	echo "==> Stapling"
	# Stapling puts the ticket in the file, so a first launch works offline.
	xcrun stapler staple "$DMG"
	xcrun stapler validate "$DMG"
fi

echo "==> Checksum"
shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo
echo "Ready: $DMG"
echo
echo "Publish it:"
echo "  git tag v$VERSION && git push origin v$VERSION"
echo "  gh release create v$VERSION \"$DMG\" \"$DMG.sha256\" --generate-notes"
