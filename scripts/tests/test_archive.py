"""Packaging keeps the visible saver version aligned with bundle metadata."""
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

PROJECT = Path(__file__).parents[2]


@unittest.skipUnless(shutil.which("ditto") and shutil.which("make"), "macOS packaging tools required")
class ArchiveTests(unittest.TestCase):
    def make_fixture(self, root, version="0.7.4", build="22"):
        (root / "Version.xcconfig").write_text(
            f"MARKETING_VERSION = {version}\nCURRENT_PROJECT_VERSION = {build}\n")
        bundles = []
        for name, identifier in [("PlexSaver.saver", "com.montage.Montage"),
                                 ("Montage Options.app", "com.montage.Options")]:
            bundle = root / "products" / name
            resources = bundle / "Contents/Resources"
            resources.mkdir(parents=True, exist_ok=True)
            (resources / "current.txt").write_text("current")
            with (bundle / "Contents/Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleIdentifier": identifier,
                              "CFBundleShortVersionString": version,
                              "CFBundleVersion": build}, stream)
            bundles.append(bundle)
        return bundles

    def command(self, bundles):
        return ["make", "-f", str(PROJECT / "Makefile"), "-o", "build", "-o", "validate",
                "archive", f"BUILT_SAVER={bundles[0]}", f"BUILT_OPTIONS={bundles[1]}"]

    def testSecondArchiveContainsOnlyCurrentVersionAndResources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundles = self.make_fixture(root)
            obsolete_files = [bundle / "Contents/Resources/obsolete.txt" for bundle in bundles]
            for obsolete in obsolete_files:
                obsolete.write_text("obsolete")
            subprocess.run(self.command(bundles), cwd=root, capture_output=True, check=True)
            archive = root / "build/release/Montage.saver.zip"
            with zipfile.ZipFile(archive) as zipped:
                self.assertIn("Montage v0.7.4.saver/Contents/Resources/obsolete.txt", zipped.namelist())
            options_archive = root / "build/release/Montage.Options.zip"
            with zipfile.ZipFile(options_archive) as zipped:
                self.assertIn("Montage Options.app/Contents/Resources/obsolete.txt", zipped.namelist())
            for obsolete in obsolete_files:
                obsolete.unlink()
            self.make_fixture(root, version="0.7.5", build="23")
            subprocess.run(self.command(bundles), cwd=root, capture_output=True, check=True)
            with zipfile.ZipFile(archive) as zipped:
                self.assertIn("Montage v0.7.5.saver/Contents/Resources/current.txt", zipped.namelist())
                self.assertNotIn("Montage v0.7.5.saver/Contents/Resources/obsolete.txt", zipped.namelist())
                self.assertTrue(all(name.startswith(("Montage v0.7.5.saver/", "__MACOSX/")) for name in zipped.namelist()))
                info = plistlib.loads(zipped.read("Montage v0.7.5.saver/Contents/Info.plist"))
                self.assertEqual(info["CFBundleShortVersionString"], "0.7.5")
            with zipfile.ZipFile(options_archive) as zipped:
                self.assertIn("Montage Options.app/Contents/Resources/current.txt", zipped.namelist())
                self.assertNotIn("Montage Options.app/Contents/Resources/obsolete.txt", zipped.namelist())
                self.assertTrue(all(name.startswith(("Montage Options.app/", "__MACOSX/")) for name in zipped.namelist()))
            self.assertFalse(list((root / "build/release").glob(".archive-*")))

    def testSourceVersionMismatchPreservesExistingArchives(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundles = self.make_fixture(root)
            command = self.command(bundles)
            subprocess.run(command, cwd=root, capture_output=True, check=True)
            archives = [root / "build/release" / name for name in ("Montage.saver.zip", "Montage.Options.zip")]
            originals = [archive.read_bytes() for archive in archives]
            (root / "Version.xcconfig").write_text("MARKETING_VERSION = 0.7.5\nCURRENT_PROJECT_VERSION = 23\n")
            result = subprocess.run(command, cwd=root, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Archive bundle versions do not match", result.stderr)
            self.assertEqual([archive.read_bytes() for archive in archives], originals)


class ReleasePublicationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.release = Path(temporary.name)
        self.staging = self.release / ".release-test"
        self.staging.mkdir()
        self.artifacts = [("Montage.saver.zip", "Montage v0.7.4.saver", "com.montage.Montage"),
                          ("Montage.Options.zip", "Montage Options.app", "com.montage.Options")]
        script = (PROJECT / "scripts/release.sh").read_text()
        self.publisher = script.split("<<'PYPUBLISH'\n", 1)[1].split("\nPYPUBLISH", 1)[0]
        for name, bundle, identifier in self.artifacts:
            self.archive(self.staging / name, bundle, identifier, "0.7.4", "22", "new")

    def archive(self, target, root, identifier, version, build, payload):
        with zipfile.ZipFile(target, "w") as archive:
            archive.writestr(f"{root}/Contents/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                "CFBundleVersion": build}))
            archive.writestr(f"{root}/Contents/Resources/current.txt", payload)

    def publish(self):
        return subprocess.run([sys.executable, "-", str(self.staging), "0.7.4"],
                              input=self.publisher, capture_output=True, text=True)

    def testRecognizesPreviousStableAndVersionedReleaseArtifacts(self):
        for previous_root in ("Montage.saver", "Montage v0.7.3.saver", "Montage_v0.7.3.saver"):
            with self.subTest(previous_root=previous_root):
                self.setUp()
                self.archive(self.release / "Montage.saver.zip", previous_root,
                             "com.montage.Montage", "0.7.3", "21", "old")
                self.archive(self.release / "Montage.Options.zip", "Montage Options.app",
                             "com.montage.Options", "0.7.3", "21", "old")
                result = self.publish()
                self.assertEqual(result.returncode, 0, result.stderr)
                with zipfile.ZipFile(self.release / "Montage.saver.zip") as archive:
                    self.assertEqual(archive.read("Montage v0.7.4.saver/Contents/Resources/current.txt"), b"new")

    def testRejectsSaverFilenameThatMisrepresentsItsVersion(self):
        self.archive(self.staging / "Montage.saver.zip", "Montage v0.7.3.saver",
                     "com.montage.Montage", "0.7.4", "22", "new")
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bundle filename does not match its version", result.stderr)
        self.assertFalse((self.release / "Montage.saver.zip").exists())

    def testRejectsOptionsBuildMismatchBeforeReplacingEitherArchive(self):
        for name, bundle, identifier in self.artifacts:
            previous_root = "Montage.saver" if name == "Montage.saver.zip" else bundle
            self.archive(self.release / name, previous_root, identifier, "0.7.3", "21", "old")
        originals = [(self.release / name).read_bytes() for name, _, _ in self.artifacts]
        self.archive(self.staging / "Montage.Options.zip", "Montage Options.app",
                     "com.montage.Options", "0.7.4", "23", "new")
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("matching versions and builds", result.stderr)
        self.assertEqual([(self.release / name).read_bytes() for name, _, _ in self.artifacts], originals)

    def testUnrelatedExistingArtifactCannotBeReplaced(self):
        target = self.release / "Montage.saver.zip"
        self.archive(target, "Montage.saver", "com.other.saver", "0.7.3", "21", "unrelated")
        original = target.read_bytes()
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unrelated bundle identifier", result.stderr)
        self.assertEqual(target.read_bytes(), original)
        self.assertFalse((self.release / "Montage.Options.zip").exists())


if __name__ == "__main__":
    unittest.main()
