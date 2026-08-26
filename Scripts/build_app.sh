#!/bin/bash
# Builds PrompterVideoMaker.app: release build (universal if possible),
# bundle assembly, icon, Developer ID codesign with hardened runtime.
# Usage: Scripts/build_app.sh [scratch-dir]
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${1:-$PROJ/.build}"
DIST="$PROJ/dist"
APP="$DIST/PrompterVideoMaker.app"
IDENTITY="Developer ID Application: Marco Tempest (Z3U3NKMU2Y)"

echo "==> Building (release)…"
cd "$PROJ"
# Universal (two-arch) builds need xcbuild, which ships with full Xcode.
if [[ -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH" 2>/dev/null; then
    BINDIR="$SCRATCH/apple/Products/Release"
    echo "    universal binary (arm64 + x86_64)"
else
    echo "    universal build unavailable, building arm64 only"
    swift build -c release --scratch-path "$SCRATCH"
    BINDIR="$SCRATCH/release"
fi
BIN="$BINDIR/PrompterVideoMaker"
[[ -f "$BIN" ]] || { echo "build product not found: $BIN" >&2; exit 1; }

echo "==> Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PrompterVideoMaker"
cp "$PROJ/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Icon…"
ICONDIR="$SCRATCH/AppIcon.iconset"
rm -rf "$ICONDIR"; mkdir -p "$ICONDIR"
swift "$PROJ/Scripts/make_icon.swift" "$SCRATCH/AppIcon_1024.png" >/dev/null
for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$SCRATCH/AppIcon_1024.png" --out "$ICONDIR/icon_${sz}x${sz}.png" >/dev/null
    dbl=$((sz * 2))
    sips -z $dbl $dbl "$SCRATCH/AppIcon_1024.png" --out "$ICONDIR/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONDIR" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Codesigning (Developer ID, hardened runtime)…"
codesign --force --options runtime --timestamp \
    --entitlements "$PROJ/Resources/PrompterVideoMaker.entitlements" \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Done: $APP"
