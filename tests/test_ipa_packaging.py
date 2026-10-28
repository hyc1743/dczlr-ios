import tempfile
import unittest
from pathlib import Path
import zipfile
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from tools.package_ipa import package


class IPAPackagingTests(unittest.TestCase):
    def test_legacy_importer_compatible_zip_has_no_extra_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            app=Path(temporary)/"PortLab.app"
            (app/"Frameworks").mkdir(parents=True)
            (app/"PortLab").write_bytes(b"executable")
            (app/"Info.plist").write_bytes(b"plist")
            output=Path(temporary)/"DCZL-R-unsigned.ipa"
            package(app,output)
            with zipfile.ZipFile(output) as archive:
                self.assertIsNone(archive.testzip())
                self.assertEqual(sorted(set(item.compress_type for item in archive.infolist())),[0,8])
                self.assertEqual(sorted(set(len(item.extra) for item in archive.infolist())),[0])
                self.assertIn("Payload/PortLab.app/PortLab",archive.namelist())


if __name__=="__main__":unittest.main()
