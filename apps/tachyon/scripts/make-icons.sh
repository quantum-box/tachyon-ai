#!/bin/bash
# Renders the app icon and the Mac sizes made from it.
set -euo pipefail

cd "$(dirname "$0")/.."
SET=Assets/Assets.xcassets/AppIcon.appiconset

swift scripts/make-icon.swift "$SET/icon-1024.png"
for size in 16 32 128 256 512; do
    sips -z $size $size "$SET/icon-1024.png" --out "$SET/mac-$size.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$SET/icon-1024.png" --out "$SET/mac-$size@2x.png" >/dev/null
done
