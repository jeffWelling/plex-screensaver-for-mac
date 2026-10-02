#!/usr/bin/env python3
"""Validate, stage, and replace only Montage's own screensaver bundles."""
import argparse
import hashlib
import os
import plistlib
import re
import shutil
import subprocess
import uuid
from pathlib import Path

IDENTIFIER = "com.montage.Montage"
LEGACY_NAME = re.compile(r"(?:Montage_v\d+\.\d+\.\d+|PlexSaver)\.saver")


def metadata(bundle):
    if bundle.is_symlink() or not bundle.is_dir():
        raise ValueError(f"Not a screensaver directory: {bundle}")
    with (bundle / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != IDENTIFIER:
        raise ValueError(f"Bundle is not Montage: {bundle}")
    return info


def validate(bundle):
    info = metadata(bundle)
    name = info.get("CFBundleExecutable", "")
    if not name or Path(name).name != name:
        raise ValueError("Invalid executable name")
    executable = bundle / "Contents/MacOS" / name
    if not executable.is_file() or executable.is_symlink():
        raise ValueError("Missing screensaver executable")
    architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).split()
    if not {"arm64", "x86_64"}.issubset(architectures):
        raise ValueError("Installation requires both Apple silicon and Intel architectures")
    if not info.get("CFBundleShortVersionString") or not info.get("CFBundleVersion"):
        raise ValueError("Missing bundle version")
    return info


def manifest(bundle):
    result = {}
    for item in sorted(bundle.rglob("*")):
        if item.is_symlink():
            result[str(item.relative_to(bundle))] = ("link", os.readlink(item))
        elif item.is_file():
            result[str(item.relative_to(bundle))] = ("file", hashlib.sha256(item.read_bytes()).hexdigest())
    return result


def old_bundles(directory):
    if not directory.is_dir():
        return []
    result = []
    for bundle in directory.iterdir():
        if bundle.name == "Montage.saver" or LEGACY_NAME.fullmatch(bundle.name):
            try:
                metadata(bundle)
                result.append(bundle)
            except (OSError, ValueError, plistlib.InvalidFileException):
                continue
    return result


def install(source, directory):
    info = validate(source)
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / "Montage.saver"
    if target.exists() or target.is_symlink():
        metadata(target)  # Refuse to overwrite an unrelated bundle or symlink.
    backup_directory = directory / ".Montage-backups"
    if backup_directory.is_symlink():
        raise ValueError("The Montage backup directory must not be a symlink")
    previous = backup_directory / "Previous.saver"
    if previous.exists() or previous.is_symlink():
        metadata(previous)
    key = uuid.uuid4().hex
    stage = directory / f".Montage-stage-{key}.saver"
    backup = directory / f".Montage-backup-{key}.saver"
    had_target = target.exists()
    has_previous = had_target
    replaced = False
    try:
        shutil.copytree(source, stage, symlinks=True)
        validate(stage)
        if manifest(source) != manifest(stage):
            raise ValueError("Staged bundle did not match build output")
        if had_target:
            os.replace(target, backup)
        try:
            os.replace(stage, target)
            replaced = True
        except BaseException:
            if had_target:
                os.replace(backup, target)
            raise
        # Remove legacy copies only after the validated replacement is installed.
        legacy = [old for old in old_bundles(directory) if old != target]
        if not had_target and legacy:
            # Migration from versioned installs also retains one recoverable
            # previous bundle instead of deleting the only working copy.
            def version_key(bundle):
                info = metadata(bundle)
                numbers = tuple(int(part) for part in str(info.get("CFBundleShortVersionString", "0")).split(".") if part.isdigit())
                build = str(info.get("CFBundleVersion", "0"))
                return numbers, int(build) if build.isdigit() else 0
            old = max(legacy, key=version_key)
            os.replace(old, backup)
            legacy.remove(old)
            has_previous = True
        for old in legacy:
            shutil.rmtree(old)
        if has_previous:
            backup_directory.mkdir(exist_ok=True)
            if previous.exists():
                shutil.rmtree(previous)
            os.replace(backup, previous)
        print(f"Installed Montage {info['CFBundleShortVersionString']} (build {info['CFBundleVersion']}) at {target}")
        if has_previous:
            print(f"Previous installation retained at {previous}")
        print("Close the screensaver picker with Done, quit System Settings, and reopen it to load the updated bundle.")
        print("On current macOS: Wallpaper → Screen Saver… → Custom → Other → Show All → Montage → Options…")
    finally:
        if stage.exists():
            shutil.rmtree(stage)
        # If cleanup failed after replacement, keep backup for manual recovery.
        if backup.exists() and not replaced and not target.exists():
            os.replace(backup, target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--destination", type=Path, default=Path.home() / "Library/Screen Savers")
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--uninstall", action="store_true")
    parser.add_argument("--version", action="store_true")
    args = parser.parse_args()
    if args.version:
        for bundle in old_bundles(args.destination):
            info = metadata(bundle)
            print(f"Installed: {info.get('CFBundleShortVersionString', '?')} (build {info.get('CFBundleVersion', '?')}) at {bundle}")
    elif args.uninstall:
        for bundle in old_bundles(args.destination):
            shutil.rmtree(bundle)
            print(f"Removed {bundle}")
    elif args.source is None:
        parser.error("--source is required for installation or validation")
    elif args.check_only:
        info = validate(args.source)
        print(f"Validated universal Montage {info['CFBundleShortVersionString']} (build {info['CFBundleVersion']})")
    else:
        install(args.source, args.destination)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
