#!/bin/bash
# Notarizes and staples dist/PrompterVideoMaker.app, then produces the
# shareable dist/PrompterVideoMaker-1.0.zip.
# Requires a notarytool keychain profile (default "PrompterNotary"):
#   xcrun notarytool store-credentials "PrompterNotary" \
#     --apple-id YOUR_APPLE_ID --team-id Z3U3NKMU2Y --password APP_SPECIFIC_PW
# Usage: Scripts/notarize.sh [profile-name]
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
APP="$PROJ/dist/PrompterVideoMaker.app"
PROFILE="${1:-PrompterNotary}"
SUBZIP="$PROJ/dist/PrompterVideoMaker-notarize.zip"
VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo dev)"
DISTZIP="$PROJ/dist/PrompterVideoMaker-$VERSION.zip"

[[ -d "$APP" ]] || { echo "Run Scripts/build_app.sh first ($APP missing)" >&2; exit 1; }

echo "==> Zipping for submission…"
rm -f "$SUBZIP"
ditto -c -k --keepParent "$APP" "$SUBZIP"

echo "==> Submitting to Apple notary service (waits for result)…"
xcrun notarytool submit "$SUBZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Gatekeeper check…"
spctl --assess --type execute --verbose "$APP"

echo "==> Building distributable zip…"
rm -f "$DISTZIP" "$SUBZIP"
ditto -c -k --keepParent "$APP" "$DISTZIP"
echo "==> Ready to share: $DISTZIP"
