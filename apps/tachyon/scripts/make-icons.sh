#!/bin/bash
# Resizes the shared app icon for macOS.
set -euo pipefail

cd "$(dirname "$0")/.."
SET=Assets/Assets.xcassets/AppIcon.appiconset

for size in 16 32 128 256 512; do
    sips -z $size $size "$SET/icon-1024.png" --out "$SET/mac-$size.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$SET/icon-1024.png" --out "$SET/mac-$size@2x.png" >/dev/null
done
