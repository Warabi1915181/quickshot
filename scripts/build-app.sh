#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SIGNING_IDENTITY=${QUICKSHOT_SIGNING_IDENTITY:-}
if [[ -z "$SIGNING_IDENTITY" ]]; then
  # Fall back to the first Apple Development identity in the keychain. A stable
  # real identity keeps QuickShot's Screen Recording permission across rebuilds
  # (ad-hoc signing would change it every time).
  SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
    | awk -F'"' '/Apple Development/ {print $2; exit}')
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "No Apple Development signing identity found in the keychain." >&2
  echo "Set QUICKSHOT_SIGNING_IDENTITY to a certificate name or SHA-1 hash." >&2
  exit 1
fi
echo "Signing with: $SIGNING_IDENTITY"
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
