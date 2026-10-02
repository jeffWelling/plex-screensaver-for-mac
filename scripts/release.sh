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
version="$(python3 - "$source_bundle/Contents/Info.plist" <<'PYVERSION'
import plistlib, re, sys
with open(sys.argv[1], 'rb') as stream:
    version = str(plistlib.load(stream)['CFBundleShortVersionString'])
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    raise SystemExit('Invalid screensaver release version')
print(version)
PYVERSION
)"
bundle="$submission/Montage v$version.saver"
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
python3 - "$staging" "$version" <<'PYPUBLISH'
import os, plistlib, re, sys, zipfile
from pathlib import Path
staging = Path(sys.argv[1])
release = staging.parent
version = sys.argv[2]
artifacts = [('Montage.saver.zip', f'Montage v{version}.saver', 'com.montage.Montage'),
             ('Montage.Options.zip', 'Montage Options.app', 'com.montage.Options')]

def archive_metadata(path, identifier, expected_root=None):
    with zipfile.ZipFile(path) as archive:
        entries = [name for name in archive.namelist()
                   if name.endswith('/Contents/Info.plist') and name.count('/') == 2]
        if len(entries) != 1:
            raise ValueError('archive must contain one bundle at its root')
        root = entries[0].split('/')[0]
        info = plistlib.loads(archive.read(entries[0]))
    if info.get('CFBundleIdentifier') != identifier:
        raise ValueError('unrelated bundle identifier')
    archive_version = str(info.get('CFBundleShortVersionString', ''))
    if not re.fullmatch(r'\d+\.\d+\.\d+', archive_version) or not info.get('CFBundleVersion'):
        raise ValueError('invalid bundle version')
    if identifier == 'com.montage.Montage':
        allowed_roots = ('Montage.saver', f'Montage v{archive_version}.saver', f'Montage_v{archive_version}.saver')
    else:
        allowed_roots = ('Montage Options.app',)
    if root not in allowed_roots or (expected_root is not None and root != expected_root):
        raise ValueError('bundle filename does not match its version')
    return archive_version, str(info['CFBundleVersion'])

expected_versions = []
for name, root, identifier in artifacts:
    try:
        staged_version = archive_metadata(staging / name, identifier, root)
        if staged_version[0] != version:
            raise ValueError('archive version differs from signed release')
        expected_versions.append(staged_version)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        raise SystemExit(f'Refusing to publish invalid artifact {name}: {error}')
    target = release / name
    if target.is_symlink() or (target.exists() and not target.is_file()):
        raise SystemExit(f'Refusing to replace non-file or symlink artifact: {target}')
    if target.exists():
        try:
            archive_metadata(target, identifier)
        except (OSError, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
            raise SystemExit(f'Refusing to replace unrelated artifact {target}: {error}')
if len(set(expected_versions)) != 1:
    raise SystemExit('Screensaver and Options release archives must have matching versions and builds')
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
