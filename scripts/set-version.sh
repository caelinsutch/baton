#!/usr/bin/env bash
#
# Sets the version everywhere. Info.plist is the single source of truth, and
# this keeps the Swift constant in step with it.
#
# Usage:
#   scripts/set-version.sh 0.2.0

set -euo pipefail

VERSION="${1:-}"
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
	echo "Usage: scripts/set-version.sh <major.minor.patch>" >&2
	exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$ROOT/Sources/BatonApp/Resources/Info.plist"
SWIFT_FILE="$ROOT/Sources/BatonMCP/MCPServer.swift"

# CFBundleVersion must increase on every build. Use the commit count.
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"

# The MCP server reports this string in its `initialize` reply.
sed -i '' "s/static let current = \".*\"/static let current = \"$VERSION\"/" "$SWIFT_FILE"

echo "Version set to $VERSION (build $BUILD)"
grep -n 'static let current' "$SWIFT_FILE"
