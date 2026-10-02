#!/usr/bin/env python3
"""Update both target versions through their shared build configuration."""
import re
import sys
from pathlib import Path

path = Path(__file__).resolve().parent.parent / "Version.xcconfig"
text = path.read_text()
match = re.search(r"^MARKETING_VERSION = (\d+)\.(\d+)\.(\d+)$", text, re.M)
if match is None or len(sys.argv) != 2 or sys.argv[1] not in {"patch", "minor", "major"}:
    raise SystemExit("Usage: bump-version.py patch|minor|major")
major, minor, patch = map(int, match.groups())
part = sys.argv[1]
version = f"{major}.{minor}.{patch + 1}" if part == "patch" else f"{major}.{minor + 1}.0" if part == "minor" else f"{major + 1}.0.0"
build = re.search(r"^CURRENT_PROJECT_VERSION = (\d+)$", text, re.M)
if build is None:
    raise SystemExit("Missing CURRENT_PROJECT_VERSION")
text = re.sub(r"^MARKETING_VERSION = .*", f"MARKETING_VERSION = {version}", text, flags=re.M)
text = re.sub(r"^CURRENT_PROJECT_VERSION = .*", f"CURRENT_PROJECT_VERSION = {int(build.group(1)) + 1}", text, flags=re.M)
path.write_text(text)
print(f"Version {version}, build {int(build.group(1)) + 1}")
