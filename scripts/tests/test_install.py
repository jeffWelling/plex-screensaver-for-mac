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


class InstallFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.bundle(self.root / "build/PlexSaver.saver", b"new", "0.6.0")
        self.destination = self.root / "Library/Screen Savers"
        self.saver_target = self.destination / "Montage v0.6.0.saver"
        self.architectures = patch.object(installer.subprocess, "check_output", return_value="arm64 x86_64\n")
        self.architectures.start()
        self.addCleanup(self.architectures.stop)

    def bundle(self, path, payload, version, identifier=installer.IDENTIFIER, build="16"):
        executable = path / "Contents/MacOS/PlexSaver"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(payload)
        with (path / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleExecutable": "PlexSaver",
                          "CFBundleShortVersionString": version, "CFBundleVersion": build,
                          "CFBundleDisplayName": f"Montage v{version}" if identifier == installer.IDENTIFIER else "Montage Options",
                          "CFBundleName": f"Montage v{version}" if identifier == installer.IDENTIFIER else "Montage Options",
                          "CFBundlePackageType": "APPL" if path.suffix == ".app" else "BNDL"}, handle)
        return path

    def update_info(self, bundle, changes):
        path = bundle / "Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        for key, value in changes.items():
            if value is None:
                info.pop(key, None)
            else:
                info[key] = value
        path.write_bytes(plistlib.dumps(info))

    def payload(self, bundle):
        return (bundle / "Contents/MacOS/PlexSaver").read_bytes()



class InstallTests(InstallFixture):
    def testNewInstallCreatesDirectoryAndUsesVersionedName(self):
        with patch("builtins.print") as output:
            installer.install(self.source, self.destination)
        self.assertIn("Show All → Montage v0.6.0 → Options…", output.call_args.args[0])
        self.assertEqual(self.payload(self.saver_target), b"new")
        self.assertFalse(list(self.destination.glob(".Montage-stage-*")))

    def testReplacementRetainsPreviousInstallation(self):
        previous = self.bundle(self.destination / "Montage.saver", b"old", "0.5.6")
        self.update_info(previous, {"CFBundleDisplayName": "Montage", "CFBundleName": "Montage"})
        installer.install(self.source, self.destination)
        self.assertEqual(self.payload(self.saver_target), b"new")
        self.assertEqual(self.payload(self.destination / ".Montage-backups/Previous.saver"), b"old")

    def testOnlyIdentifiedExactLegacyNamesAreRemoved(self):
        legacy = self.bundle(self.destination / "Montage_v0.5.6.saver", b"legacy", "0.5.6")
        self.update_info(legacy, {"CFBundleDisplayName": None, "CFBundleName": None})
        unrelated = self.bundle(self.destination / "Montage_v0.1.0.saver", b"other", "0.1.0", "com.other.saver")
        similarly_named = self.bundle(self.destination / "MontageCustom.saver", b"custom", "0.1.0")
        installer.install(self.source, self.destination)
        self.assertFalse(legacy.exists())
        self.assertEqual(self.payload(self.destination / ".Montage-backups/Previous.saver"), b"legacy")
        self.assertTrue(unrelated.exists())
        self.assertTrue(similarly_named.exists())

    def testUnrelatedStableBundleIsPreserved(self):
        target = self.bundle(self.destination / "Montage.saver", b"unrelated", "1.0", "com.other.saver")
        installer.install(self.source, self.destination)
        self.assertEqual(self.payload(target), b"unrelated")
        self.assertEqual(self.payload(self.saver_target), b"new")

    def testUnrelatedVersionedTargetCannotBeOverwritten(self):
        target = self.bundle(self.saver_target, b"unrelated", "0.6.0", "com.other.saver")
        with self.assertRaises(ValueError):
            installer.install(self.source, self.destination)
        self.assertEqual(self.payload(target), b"unrelated")

    def testVersionedUpgradeKeepsNewestPreviousAndRemovesRecognizedCopies(self):
        older = self.bundle(self.destination / "Montage v0.4.9.saver", b"older", "0.4.9")
        newest = self.bundle(self.destination / "Montage v0.5.10.saver", b"newest", "0.5.10")
        stable = self.bundle(self.destination / "Montage.saver", b"stable", "0.5.9")
        unrelated = self.bundle(self.destination / "Montage v0.1.0.saver", b"other", "0.1.0", "com.other.saver")
        installer.install(self.source, self.destination)
        self.assertEqual(self.payload(self.saver_target), b"new")
        self.assertEqual(self.payload(self.destination / ".Montage-backups/Previous.saver"), b"newest")
        self.assertFalse(older.exists())
        self.assertFalse(newest.exists())
        self.assertFalse(stable.exists())
        self.assertTrue(unrelated.exists())

    def testSameVersionReplacementRetainsPreviousBuild(self):
        self.bundle(self.saver_target, b"previous build", "0.6.0", build="15")
        installer.install(self.source, self.destination)
        self.assertEqual(self.payload(self.saver_target), b"new")
        self.assertEqual(self.payload(self.destination / ".Montage-backups/Previous.saver"), b"previous build")

    def testCurrentTargetReplacementKeepsNewerStableCopy(self):
        self.bundle(self.saver_target, b"older target", "0.6.0", build="14")
        stable = self.bundle(self.destination / "Montage.saver", b"newer stable", "0.6.0", build="15")
        installer.install(self.source, self.destination)
        self.assertEqual(self.payload(self.saver_target), b"new")
        self.assertEqual(self.payload(self.destination / ".Montage-backups/Previous.saver"), b"newer stable")
        self.assertFalse(stable.exists())
        self.assertFalse(list(self.destination.glob(".Montage-backup-*.saver")))

    def testFailedSecuringNewerCopyPreservesBothPreviousCopies(self):
        self.bundle(self.saver_target, b"older target", "0.6.0", build="14")
        stable = self.bundle(self.destination / "Montage.saver", b"newer stable", "0.6.0", build="15")
        replace = installer.os.replace
        def fail_newest(source, destination):
            if Path(source) == stable:
                raise OSError("Cannot secure newest previous copy")
            return replace(source, destination)
        with patch.object(installer.os, "replace", side_effect=fail_newest):
            with self.assertRaises(OSError):
                installer.install(self.source, self.destination)
        self.assertEqual(self.payload(stable), b"newer stable")
        self.assertEqual(self.payload(self.saver_target), b"new")
        backups = list(self.destination.glob(".Montage-backup-*.saver"))
        self.assertEqual([self.payload(bundle) for bundle in backups], [b"older target"])

    def testFailedFinalRetentionPreservesSecuredNewestAndOlderCopies(self):
        self.bundle(self.saver_target, b"older target", "0.6.0", build="14")
        stable = self.bundle(self.destination / "Montage.saver", b"newer stable", "0.6.0", build="15")
        previous = self.destination / ".Montage-backups/Previous.saver"
        replace = installer.os.replace
        def fail_retention(source, destination):
            if Path(destination) == previous:
                raise OSError("Cannot retain newest previous copy")
            return replace(source, destination)
        with patch.object(installer.os, "replace", side_effect=fail_retention):
            with self.assertRaises(OSError):
                installer.install(self.source, self.destination)
        self.assertEqual(self.payload(self.saver_target), b"new")
        backups = list(self.destination.glob(".Montage-backup-*.saver"))
        self.assertEqual({self.payload(bundle) for bundle in backups}, {b"older target", b"newer stable"})
        self.assertFalse(stable.exists())

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

    def testMissingPickerNamesCannotInstall(self):
        for key in ("CFBundleDisplayName", "CFBundleName"):
            with self.subTest(missing=key):
                self.update_info(self.source, {"CFBundleDisplayName": "Montage v0.6.0", "CFBundleName": "Montage v0.6.0", key: None})
                with self.assertRaisesRegex(ValueError, "screensaver names"):
                    installer.install(self.source, self.destination)
                self.assertFalse(self.destination.exists())

    def testPlainPickerNamesCannotReplaceCurrentSaver(self):
        current = self.bundle(self.destination / "Montage.saver", b"old", "0.5.6")
        self.update_info(self.source, {"CFBundleDisplayName": "Montage", "CFBundleName": "Montage"})
        with self.assertRaisesRegex(ValueError, "screensaver names"):
            installer.install(self.source, self.destination)
        self.assertEqual(self.payload(current), b"old")
        self.assertFalse(list(self.destination.glob(".Montage-stage-*")))

    def testStaleVersionPickerNamesCannotInstall(self):
        self.update_info(self.source, {"CFBundleDisplayName": "Montage v0.5.6", "CFBundleName": "Montage v0.5.6"})
        with self.assertRaisesRegex(ValueError, "screensaver names"):
            installer.install(self.source, self.destination)
        self.assertFalse(self.destination.exists())

    def testOnlyOneVersionedNameCannotInstall(self):
        for correct_key in ("CFBundleDisplayName", "CFBundleName"):
            with self.subTest(correct=correct_key):
                self.update_info(self.source, {"CFBundleDisplayName": "Montage", "CFBundleName": "Montage", correct_key: "Montage v0.6.0"})
                with self.assertRaisesRegex(ValueError, "screensaver names"):
                    installer.install(self.source, self.destination)
                self.assertFalse(self.destination.exists())

    def testUnsafeVersionsCannotBecomeInstallationPaths(self):
        for version in ("../0.6.0", "0.6.0/Other", "/tmp/escape", "0.6.0\\Other", "0.6.0$(id)"):
            with self.subTest(version=version):
                self.update_info(self.source, {"CFBundleShortVersionString": version, "CFBundleDisplayName": f"Montage v{version}", "CFBundleName": f"Montage v{version}"})
                with self.assertRaisesRegex(ValueError, "three numeric components"):
                    installer.install(self.source, self.destination)
                self.assertFalse(self.destination.exists())

    def testBundleSymlinkCannotBeFollowed(self):
        link = self.root / "linked.saver"
        link.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(ValueError):
            installer.validate(link)


class OptionsInstallTests(InstallFixture):
    def setUp(self):
        super().setUp()
        self.options_source = self.bundle(self.root / "build/Montage Options.app", b"new options", "0.6.0", installer.OPTIONS_IDENTIFIER)
        self.options_directory = self.root / "Applications"
        self.options_target = self.options_directory / installer.OPTIONS_NAME

    def install_pair(self):
        installer.install(self.source, self.destination, self.options_source, self.options_directory)

    def installed_pair(self):
        saver = self.bundle(self.destination / "Montage.saver", b"old", "0.5.6")
        self.bundle(self.options_target, b"old options", "0.5.6", installer.OPTIONS_IDENTIFIER)
        return saver

    def assert_old_pair(self, saver):
        self.assertEqual(self.payload(saver), b"old")
        self.assertEqual(self.payload(self.options_target), b"old options")
        self.assertFalse(list(self.destination.glob(".Montage-stage-*")))
        self.assertFalse(list(self.options_directory.glob(".Montage-Options-stage-*")))

    def testPairReplacementRetainsBothPreviousBundles(self):
        self.installed_pair()
        self.install_pair()
        self.assertEqual(self.payload(self.saver_target), b"new")
        self.assertEqual(self.payload(self.options_target), b"new options")
        self.assertEqual(self.payload(self.options_directory / ".Montage-Options-backups/Previous.app"), b"old options")
        self.assertEqual(self.payload(self.destination / ".Montage-backups/Previous.saver"), b"old")

    def testOptionsVersionMismatchDoesNotTouchEitherDestination(self):
        saver = self.installed_pair()
        info_path = self.options_source / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleShortVersionString"] = "0.7.0"
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "matching versions"):
            self.install_pair()
        self.assert_old_pair(saver)

    def testOptionsBuildMismatchRejectsNewInstallationBeforeCreatingDirectories(self):
        info_path = self.options_source / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleVersion"] = "17"
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "matching versions"):
            self.install_pair()
        self.assertFalse(self.destination.exists())
        self.assertFalse(self.options_directory.exists())

    def testOptionsIncompleteArchitectureRejectsPair(self):
        def architecture(command, **kwargs):
            return "arm64" if "Montage Options.app" in command[-1] else "arm64 x86_64"
        with patch.object(installer.subprocess, "check_output", side_effect=architecture):
            with self.assertRaisesRegex(ValueError, "Intel"):
                self.install_pair()
        self.assertFalse(self.destination.exists())

    def testUnrelatedOptionsCannotOverwriteExistingSaverOrApp(self):
        saver = self.bundle(self.destination / "Montage.saver", b"old", "0.5.6")
        self.bundle(self.options_target, b"other app", "1.0", "com.other.App")
        with self.assertRaises(ValueError):
            self.install_pair()
        self.assertEqual(self.payload(saver), b"old")
        self.assertEqual(self.payload(self.options_target), b"other app")

    def testSymlinkOptionsTargetIsNotFollowed(self):
        saver = self.bundle(self.destination / "Montage.saver", b"old", "0.5.6")
        self.options_directory.mkdir()
        self.options_target.symlink_to(self.options_source, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.install_pair()
        self.assertTrue(self.options_target.is_symlink())
        self.assertEqual(self.payload(saver), b"old")
        self.assertEqual(self.payload(self.options_source), b"new options")

    def testSymlinkOptionsDirectoryIsNotFollowed(self):
        real_directory = self.root / "Other Applications"
        real_directory.mkdir()
        self.options_directory.symlink_to(real_directory, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinks"):
            self.install_pair()
        self.assertEqual(list(real_directory.iterdir()), [])
        self.assertFalse(self.destination.exists())

    def testOptionsCopyFailurePreservesBothCurrentBundles(self):
        saver = self.installed_pair()
        copytree = installer.shutil.copytree
        def fail_options(source, destination, *args, **kwargs):
            if Path(source) == self.options_source:
                raise OSError("Options copy failed")
            return copytree(source, destination, *args, **kwargs)
        with patch.object(installer.shutil, "copytree", side_effect=fail_options):
            with self.assertRaises(OSError):
                self.install_pair()
        self.assert_old_pair(saver)

    def testOptionsReplacementFailureRestoresAlreadyReplacedSaver(self):
        saver = self.installed_pair()
        replace = installer.os.replace
        def fail_options(source, destination):
            if Path(source).name.startswith(".Montage-Options-stage-"):
                raise OSError("Options replace failed")
            return replace(source, destination)
        with patch.object(installer.os, "replace", side_effect=fail_options):
            with self.assertRaises(OSError):
                self.install_pair()
        self.assert_old_pair(saver)
        self.assertFalse(self.saver_target.exists())

    def testFailedNewPairReplacementRemovesNewSaver(self):
        replace = installer.os.replace
        def fail_options(source, destination):
            if Path(source).name.startswith(".Montage-Options-stage-"):
                raise OSError("Options replace failed")
            return replace(source, destination)
        with patch.object(installer.os, "replace", side_effect=fail_options):
            with self.assertRaises(OSError):
                self.install_pair()
        self.assertFalse(self.saver_target.exists())
        self.assertFalse(self.options_target.exists())

    def testUninstallRemovesOnlyIdentifiedOptionsApp(self):
        self.bundle(self.options_target, b"own", "0.5.6", installer.OPTIONS_IDENTIFIER)
        unrelated = self.bundle(self.options_directory / "Montage Other.app", b"other", "1.0", "com.other.App")
        installer.uninstall_options(self.options_directory)
        self.assertFalse(self.options_target.exists())
        self.assertTrue(unrelated.exists())

    def testUninstallPreservesUnrelatedOrSymlinkOptionsApp(self):
        self.bundle(self.options_target, b"other", "1.0", "com.other.App")
        installer.uninstall_options(self.options_directory)
        self.assertEqual(self.payload(self.options_target), b"other")
        installer.shutil.rmtree(self.options_target)
        self.options_target.symlink_to(self.options_source, target_is_directory=True)
        installer.uninstall_options(self.options_directory)
        self.assertTrue(self.options_target.is_symlink())
        self.assertTrue(self.options_source.exists())

    def testSaverOnlyInstallationDoesNotTouchOptions(self):
        self.bundle(self.options_target, b"other", "1.0", "com.other.App")
        installer.install(self.source, self.destination)
        self.assertEqual(self.payload(self.options_target), b"other")


if __name__ == "__main__":
    unittest.main()
