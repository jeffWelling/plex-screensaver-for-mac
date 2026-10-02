"""Installation transactions are tested without touching a user's Library."""
import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("montage_install", Path(__file__).parents[1] / "install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.bundle(self.root / "build/PlexSaver.saver", b"new", "0.6.0")
        self.destination = self.root / "Library/Screen Savers"
        self.architectures = patch.object(installer.subprocess, "check_output", return_value="arm64 x86_64\n")
        self.architectures.start()
        self.addCleanup(self.architectures.stop)

    def bundle(self, path, payload, version, identifier=installer.IDENTIFIER):
        executable = path / "Contents/MacOS/PlexSaver"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(payload)
        with (path / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleExecutable": "PlexSaver",
                          "CFBundleShortVersionString": version, "CFBundleVersion": "16"}, handle)
        return path

    def payload(self, bundle):
        return (bundle / "Contents/MacOS/PlexSaver").read_bytes()

    def testNewInstallCreatesDirectoryAndUsesStableName(self):
        installer.install(self.source, self.destination)
        self.assertEqual(self.payload(self.destination / "Montage.saver"), b"new")
        self.assertFalse(list(self.destination.glob(".Montage-stage-*")))

    def testReplacementRetainsPreviousInstallation(self):
        self.bundle(self.destination / "Montage.saver", b"old", "0.5.6")
        installer.install(self.source, self.destination)
        self.assertEqual(self.payload(self.destination / "Montage.saver"), b"new")
        self.assertEqual(self.payload(self.destination / ".Montage-backups/Previous.saver"), b"old")

    def testOnlyIdentifiedExactLegacyNamesAreRemoved(self):
        legacy = self.bundle(self.destination / "Montage_v0.5.6.saver", b"legacy", "0.5.6")
        unrelated = self.bundle(self.destination / "Montage_v0.1.0.saver", b"other", "0.1.0", "com.other.saver")
        similarly_named = self.bundle(self.destination / "MontageCustom.saver", b"custom", "0.1.0")
        installer.install(self.source, self.destination)
        self.assertFalse(legacy.exists())
        self.assertEqual(self.payload(self.destination / ".Montage-backups/Previous.saver"), b"legacy")
        self.assertTrue(unrelated.exists())
        self.assertTrue(similarly_named.exists())

    def testUnrelatedStableBundleCannotBeOverwritten(self):
        target = self.bundle(self.destination / "Montage.saver", b"unrelated", "1.0", "com.other.saver")
        with self.assertRaises(ValueError):
            installer.install(self.source, self.destination)
        self.assertEqual(self.payload(target), b"unrelated")

    def testCopyFailurePreservesCurrentBundle(self):
        target = self.bundle(self.destination / "Montage.saver", b"old", "0.5.6")
        with patch.object(installer.shutil, "copytree", side_effect=OSError("copy failed")):
            with self.assertRaises(OSError):
                installer.install(self.source, self.destination)
        self.assertEqual(self.payload(target), b"old")

    def testReplacementFailureRollsBackCurrentBundle(self):
        target = self.bundle(self.destination / "Montage.saver", b"old", "0.5.6")
        replace = installer.os.replace

        def fail_stage(source, destination):
            if Path(source).name.startswith(".Montage-stage-"):
                raise OSError("replace failed")
            return replace(source, destination)

        with patch.object(installer.os, "replace", side_effect=fail_stage):
            with self.assertRaises(OSError):
                installer.install(self.source, self.destination)
        self.assertEqual(self.payload(target), b"old")
        self.assertFalse(list(self.destination.glob(".Montage-stage-*")))

    def testIncompleteArchitectureBuildCannotInstall(self):
        with patch.object(installer.subprocess, "check_output", return_value="arm64\n"):
            with self.assertRaises(ValueError):
                installer.install(self.source, self.destination)
        self.assertFalse(self.destination.exists())

    def testBundleSymlinkCannotBeFollowed(self):
        link = self.root / "linked.saver"
        link.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(ValueError):
            installer.validate(link)


if __name__ == "__main__":
    unittest.main()
