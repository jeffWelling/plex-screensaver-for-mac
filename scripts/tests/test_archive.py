"""Archive staging must never retain resources from a previous bundle."""
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path


@unittest.skipUnless(shutil.which("ditto") and shutil.which("make"), "macOS packaging tools required")
class ArchiveTests(unittest.TestCase):
    def testSecondArchiveContainsOnlyCurrentResources(self):
        project = Path(__file__).parents[2]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copyfile(project / "Version.xcconfig", root / "Version.xcconfig")
            bundle = root / "products/PlexSaver.saver"
            resources = bundle / "Contents/Resources"
            resources.mkdir(parents=True)
            (resources / "current.txt").write_text("current")
            obsolete = resources / "obsolete.txt"
            obsolete.write_text("obsolete")
            command = ["make", "-f", str(project / "Makefile"), "-o", "build", "-o", "validate",
                       "archive", f"BUILT_SAVER={bundle}"]
            subprocess.run(command, cwd=root, capture_output=True, check=True)
            archive = root / "build/release/Montage.saver.zip"
            with zipfile.ZipFile(archive) as zipped:
                self.assertIn("Montage.saver/Contents/Resources/obsolete.txt", zipped.namelist())
            obsolete.unlink()
            subprocess.run(command, cwd=root, capture_output=True, check=True)
            with zipfile.ZipFile(archive) as zipped:
                self.assertIn("Montage.saver/Contents/Resources/current.txt", zipped.namelist())
                self.assertNotIn("Montage.saver/Contents/Resources/obsolete.txt", zipped.namelist())
            self.assertFalse(list((root / "build/release").glob(".archive-*")))


if __name__ == "__main__":
    unittest.main()
