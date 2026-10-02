#!/usr/bin/env python3
"""Validate and replace Montage's screensaver and optional Options app."""
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
OPTIONS_IDENTIFIER = "com.montage.Options"
OPTIONS_NAME = "Montage Options.app"
VERSIONED_NAME = re.compile(r"(?:Montage v|Montage_v)[0-9]+\.[0-9]+\.[0-9]+\.saver")


def metadata(bundle, identifier=IDENTIFIER):
    if bundle.is_symlink() or not bundle.is_dir():
        raise ValueError(f"Not a bundle directory: {bundle}")
    for component in (bundle / "Contents", bundle / "Contents/Info.plist"):
        if component.is_symlink():
            raise ValueError(f"Bundle metadata must not be a symlink: {component}")
    with (bundle / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != identifier:
        raise ValueError(f"Bundle is not {identifier}: {bundle}")
    return info


def validate(bundle, identifier=IDENTIFIER):
    info = metadata(bundle, identifier)
    name = info.get("CFBundleExecutable", "")
    if not isinstance(name, str) or not name or Path(name).name != name:
        raise ValueError("Invalid executable name")
    executable = bundle / "Contents/MacOS" / name
    if (bundle / "Contents/MacOS").is_symlink() or not executable.is_file() or executable.is_symlink():
        raise ValueError("Missing bundle executable or executable is a symlink")
    architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).split()
    if not {"arm64", "x86_64"}.issubset(architectures):
        raise ValueError("Installation requires both Apple silicon and Intel architectures")
    if not info.get("CFBundleShortVersionString") or not info.get("CFBundleVersion"):
        raise ValueError("Missing bundle version")
    if identifier == IDENTIFIER:
        version = info["CFBundleShortVersionString"]
        if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
            raise ValueError("Screensaver version must contain three numeric components")
        expected_name = f"Montage v{version}"
        if any(info.get(key) != expected_name for key in ("CFBundleDisplayName", "CFBundleName")):
            raise ValueError(f"Both screensaver names must equal {expected_name}")
    if identifier == OPTIONS_IDENTIFIER and info.get("CFBundlePackageType") != "APPL":
        raise ValueError("The Options bundle must be a macOS application")
    return info


def versions(info):
    return str(info["CFBundleShortVersionString"]), str(info["CFBundleVersion"])


def validate_pair(source, options_source=None):
    saver_info = validate(source)
    if options_source is not None:
        options_info = validate(options_source, OPTIONS_IDENTIFIER)
        if versions(saver_info) != versions(options_info):
            raise ValueError("Screensaver and Options app must have matching versions and builds")
    return saver_info


def manifest(bundle):
    result = {}
    for item in sorted(bundle.rglob("*")):
        if item.is_symlink():
            result[str(item.relative_to(bundle))] = ("link", os.readlink(item))
        elif item.is_file():
            result[str(item.relative_to(bundle))] = ("file", hashlib.sha256(item.read_bytes()).hexdigest())
    return result


def old_bundles(directory):
    if directory.is_symlink() or not directory.is_dir():
        return []
    result = []
    for bundle in directory.iterdir():
        if bundle.name in {"Montage.saver", "PlexSaver.saver"} or VERSIONED_NAME.fullmatch(bundle.name):
            try:
                metadata(bundle)
                result.append(bundle)
            except (OSError, ValueError, plistlib.InvalidFileException):
                continue
    return result


def safe_directory(directory):
    for component in (directory, *directory.absolute().parents):
        if component.is_symlink():
            raise ValueError(f"Installation directory must not contain symlinks: {component}")
        if component.exists() and not component.is_dir():
            raise ValueError(f"Installation directory is not a directory: {component}")


class Replacement:
    def __init__(self, source, directory, name, identifier, prefix, previous_name):
        self.source, self.directory, self.identifier = source, directory, identifier
        self.target = directory / name
        self.backup_directory = directory / f".{prefix}-backups"
        self.previous = self.backup_directory / previous_name
        key = uuid.uuid4().hex
        suffix = Path(name).suffix
        self.stage = directory / f".{prefix}-stage-{key}{suffix}"
        self.backup = directory / f".{prefix}-backup-{key}{suffix}"
        self.had_target = False
        self.moved_target = False
        self.replaced = False

    def preflight(self):
        safe_directory(self.directory)
        safe_directory(self.backup_directory)
        for bundle in (self.target, self.previous):
            if bundle.exists() or bundle.is_symlink():
                metadata(bundle, self.identifier)
        self.had_target = self.target.exists()

    def prepare(self, expected_version):
        self.directory.mkdir(parents=True, exist_ok=True)
        shutil.copytree(self.source, self.stage, symlinks=True)
        info = validate(self.stage, self.identifier)
        if versions(info) != expected_version or manifest(self.source) != manifest(self.stage):
            raise ValueError("Staged bundle did not match build output")

    def replace(self):
        if self.had_target:
            os.replace(self.target, self.backup)
            self.moved_target = True
        os.replace(self.stage, self.target)
        self.replaced = True

    def rollback(self):
        if self.replaced and self.target.exists():
            shutil.rmtree(self.target)
        if self.moved_target and self.backup.exists():
            os.replace(self.backup, self.target)
        self.replaced = False

    def retain_previous(self):
        if self.backup.exists():
            self.backup_directory.mkdir(exist_ok=True)
            if self.previous.exists():
                shutil.rmtree(self.previous)
            os.replace(self.backup, self.previous)

    def cleanup_stage(self):
        if self.stage.exists():
            shutil.rmtree(self.stage)


def install(source, directory, options_source=None, options_directory=None):
    info = validate_pair(source, options_source)
    saver = Replacement(source, directory, f"Montage v{info['CFBundleShortVersionString']}.saver",
                        IDENTIFIER, "Montage", "Previous.saver")
    plans = [saver]
    if options_source is not None:
        options_directory = options_directory or Path.home() / "Applications"
        plans.append(Replacement(options_source, options_directory, OPTIONS_NAME, OPTIONS_IDENTIFIER,
                                 "Montage-Options", "Previous.app"))
    # Check both destinations before staging or changing either installed bundle.
    for plan in plans:
        plan.preflight()
    try:
        for plan in plans:
            plan.prepare(versions(info))
        try:
            for plan in plans:
                plan.replace()
        except BaseException as installation_error:
            # Each destination rename is atomic. Restore the pair on failure,
            # including the saver if installing the companion was the failure.
            rollback_errors = []
            for plan in reversed(plans):
                try:
                    plan.rollback()
                except OSError as error:
                    rollback_errors.append(f"{plan.target}: {error}; recover from {plan.backup}")
            if rollback_errors:
                raise OSError("Installation failed; rollback needs recovery: " + "; ".join(rollback_errors)) from installation_error
            raise
        # Remove identified legacy copies only once the replacement pair exists.
        legacy = [old for old in old_bundles(directory) if old != saver.target]
        candidates = ([saver.backup] if saver.backup.exists() else []) + legacy
        obsolete_backup = None
        if candidates:
            def version_key(bundle):
                old_info = metadata(bundle)
                numbers = tuple(int(part) for part in str(old_info.get("CFBundleShortVersionString", "0")).split(".") if part.isdigit())
                build = str(old_info.get("CFBundleVersion", "0"))
                return numbers, int(build) if build.isdigit() else 0
            newest = max(candidates, key=version_key)
            if newest != saver.backup:
                # Secure the newest copy before removing the replaced target's
                # backup. Either failed move leaves that newest copy recoverable.
                secured = directory / f".Montage-backup-{uuid.uuid4().hex}.saver"
                os.replace(newest, secured)
                if saver.backup.exists():
                    obsolete_backup = saver.backup
                saver.backup = secured
                legacy.remove(newest)
        for old in legacy:
            shutil.rmtree(old)
        for plan in plans:
            plan.retain_previous()
        if obsolete_backup is not None:
            shutil.rmtree(obsolete_backup)
        print(f"Installed Montage {info['CFBundleShortVersionString']} (build {info['CFBundleVersion']}) at {saver.target}")
        for plan in plans:
            if plan.previous.exists():
                print(f"Previous installation retained at {plan.previous}")
        if options_source is not None:
            print(f"Open {plans[1].target} to configure Montage independently of System Settings.")
        print("Close the screensaver picker with Done, quit System Settings, and reopen it to load the updated bundle.")
        print(f"On current macOS: Wallpaper → Screen Saver… → Custom → Other → Show All → {info['CFBundleDisplayName']} → Options…")
    finally:
        for plan in plans:
            plan.cleanup_stage()


def installed_options(directory):
    try:
        safe_directory(directory)
    except ValueError:
        return None
    target = directory / OPTIONS_NAME
    if not target.exists() and not target.is_symlink():
        return None
    try:
        metadata(target, OPTIONS_IDENTIFIER)
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None
    return target


def uninstall_options(directory):
    target = installed_options(directory)
    if target is not None:
        shutil.rmtree(target)
        print(f"Removed {target}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--destination", type=Path, default=Path.home() / "Library/Screen Savers")
    parser.add_argument("--options-source", type=Path)
    parser.add_argument("--options-destination", type=Path, default=Path.home() / "Applications")
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--uninstall", action="store_true")
    parser.add_argument("--version", action="store_true")
    args = parser.parse_args()
    if args.version:
        bundles = [(bundle, IDENTIFIER) for bundle in old_bundles(args.destination)]
        options = installed_options(args.options_destination)
        if options is not None:
            bundles.append((options, OPTIONS_IDENTIFIER))
        for bundle, identifier in bundles:
            info = metadata(bundle, identifier)
            print(f"Installed: {info.get('CFBundleShortVersionString', '?')} (build {info.get('CFBundleVersion', '?')}) at {bundle}")
    elif args.uninstall:
        for bundle in old_bundles(args.destination):
            shutil.rmtree(bundle)
            print(f"Removed {bundle}")
        uninstall_options(args.options_destination)
    elif args.source is None:
        parser.error("--source is required for installation or validation")
    elif args.check_only:
        info = validate_pair(args.source, args.options_source)
        print(f"Validated universal Montage {info['CFBundleShortVersionString']} (build {info['CFBundleVersion']})")
        if args.options_source is not None:
            print("Validated matching universal Montage Options app")
    else:
        install(args.source, args.destination, args.options_source, args.options_destination)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
