#!/bin/bash
# Builds build/Tachyon AI.app (release, ad-hoc signed).
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/TachyonAI"

APP="build/Tachyon AI.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/TachyonAI"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sign with the certificate from create-dev-cert.sh when it exists, so macOS
# keeps the granted permissions across rebuilds. Ad-hoc signatures ("-")
# change with every build.
IDENTITY="${CODESIGN_IDENTITY:-Tachyon AI Dev}"
if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "No '$IDENTITY' certificate (run scripts/create-dev-cert.sh); signing ad-hoc."
    IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP"

echo "Built: $(pwd)/$APP"
