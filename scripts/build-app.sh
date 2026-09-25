#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SIGNING_IDENTITY=${QUICKSHOT_SIGNING_IDENTITY:-}
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "Set QUICKSHOT_SIGNING_IDENTITY to a code-signing certificate name or SHA-1 hash." >&2
  echo "Ad-hoc signing changes QuickShot's Screen Recording identity after each rebuild." >&2
  exit 1
fi
swift build -c release
APP=build/QuickShot.app
STAGING_APP=build/QuickShot-staging.app
rm -rf "$STAGING_APP"
trap 'rm -rf "$STAGING_APP"' EXIT
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
cp .build/release/QuickShot "$STAGING_APP/Contents/MacOS/QuickShot"
cp Resources/Info.plist "$STAGING_APP/Contents/Info.plist"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$STAGING_APP"
codesign --verify --strict "$STAGING_APP"
rm -rf "$APP"
mv "$STAGING_APP" "$APP"
echo "Built $APP"
