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
make build validate SCHEME=PlexSaver CONFIG=Release
source_root="${BUILD_ROOT:-$PWD/build/xcode}/Build/Products/Release"
source_bundle="$source_root/PlexSaver.saver"
source_options="$source_root/Montage Options.app"
python3 scripts/install.py --source "$source_bundle" --options-source "$source_options" --check-only
mkdir -p build/release
staging="$(mktemp -d "$PWD/build/release/.release-XXXXXX")"
trap 'if [[ -f "$staging/.retain-for-recovery" ]]; then echo "Release recovery files retained at $staging" >&2; else rm -rf "$staging"; fi' EXIT HUP INT TERM
submission="$staging/Montage"
mkdir "$submission"
bundle="$submission/Montage.saver"
options="$submission/Montage Options.app"
ditto "$source_bundle" "$bundle"
ditto "$source_options" "$options"
for product in "$bundle" "$options"; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$product"
    codesign --verify --strict --verbose=2 "$product"
done
# One submission covers both signed bundles. Distributable archives remain separate.
ditto -c -k --sequesterRsrc --keepParent "$submission" "$staging/Montage-submission.zip"
xcrun notarytool submit "$staging/Montage-submission.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$staging/notarization.json"
python3 - "$staging/notarization.json" <<'PYNOTARY'
import json, sys
with open(sys.argv[1]) as stream:
    result = json.load(stream)
if result.get('status') != 'Accepted':
    raise SystemExit(f"Notarization was not accepted: {result.get('status', 'unknown')}; submission {result.get('id', 'unknown')}")
PYNOTARY
for product in "$bundle" "$options"; do
    xcrun stapler staple "$product"
    xcrun stapler validate "$product"
    codesign --verify --strict --verbose=2 "$product"
done
ditto -c -k --sequesterRsrc --keepParent "$bundle" "$staging/Montage.saver.zip"
ditto -c -k --sequesterRsrc --keepParent "$options" "$staging/Montage.Options.zip"
# Never replace unrelated or symlink output, and restore both ZIPs if publication fails.
python3 - "$staging" <<'PYPUBLISH'
import os, plistlib, sys, zipfile
from pathlib import Path
staging = Path(sys.argv[1])
release = staging.parent
artifacts = [('Montage.saver.zip', 'Montage.saver', 'com.montage.Montage'),
             ('Montage.Options.zip', 'Montage Options.app', 'com.montage.Options')]
for name, root, identifier in artifacts:
    target = release / name
    if target.is_symlink() or (target.exists() and not target.is_file()):
        raise SystemExit(f'Refusing to replace non-file or symlink artifact: {target}')
    if target.exists():
        try:
            with zipfile.ZipFile(target) as archive:
                info = plistlib.loads(archive.read(f'{root}/Contents/Info.plist'))
            if info.get('CFBundleIdentifier') != identifier:
                raise ValueError('unrelated bundle identifier')
        except (OSError, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
            raise SystemExit(f'Refusing to replace unrelated artifact {target}: {error}')
replaced, moved = [], []
try:
    for name, _, _ in artifacts:
        target = release / name
        if target.exists():
            os.replace(target, staging / f'previous-{name}')
            moved.append(name)
        os.replace(staging / name, target)
        replaced.append(name)
except BaseException as publication_error:
    recovery_errors = []
    for name, _, _ in reversed(artifacts):
        try:
            if name in moved:
                os.replace(staging / f'previous-{name}', release / name)
            elif name in replaced:
                (release / name).unlink()
        except OSError as error:
            recovery_errors.append(f'{name}: {error}')
    if recovery_errors:
        (staging / '.retain-for-recovery').touch()
        raise OSError(f'Release publication failed; recover from {staging}: ' + '; '.join(recovery_errors)) from publication_error
    raise
PYPUBLISH
echo 'Signed and notarized artifacts: build/release/Montage.saver.zip and build/release/Montage.Options.zip'
