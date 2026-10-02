#!/bin/bash
# Explicit distribution action: requires a Developer ID identity and a
# preconfigured notarytool keychain profile, without reading secret values.
set -euo pipefail
if [[ "${1:-}" != "--notarize" ]]; then
    echo 'Usage: SIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE="..." bash scripts/release.sh --notarize'
    exit 2
fi
: "${SIGN_IDENTITY:?Supply a Developer ID Application signing identity}"
: "${NOTARY_PROFILE:?Supply an existing notarytool keychain profile}"
cd "$(dirname "$0")/.."
make build SCHEME=PlexSaver CONFIG=Release
source_bundle="${BUILD_ROOT:-$PWD/build/xcode}/Build/Products/Release/PlexSaver.saver"
python3 scripts/install.py --source "$source_bundle" --check-only
mkdir -p build/release
bundle="build/release/Montage.saver"
if [[ -e "$bundle" ]]; then
    python3 - "$bundle" <<'PY'
import plistlib, shutil, sys
from pathlib import Path
bundle = Path(sys.argv[1])
with (bundle / 'Contents/Info.plist').open('rb') as stream:
    assert plistlib.load(stream)['CFBundleIdentifier'] == 'com.montage.Montage'
shutil.rmtree(bundle)
PY
fi
ditto "$source_bundle" "$bundle"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$bundle"
codesign --verify --strict --verbose=2 "$bundle"
ditto -c -k --sequesterRsrc --keepParent "$bundle" build/release/Montage-submission.zip
xcrun notarytool submit build/release/Montage-submission.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$bundle"
xcrun stapler validate "$bundle"
ditto -c -k --sequesterRsrc --keepParent "$bundle" build/release/Montage.saver.zip
echo 'Signed and notarized artifact: build/release/Montage.saver.zip'
