import json
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from verify_ipa import inspect,macho_device

def binary(platform=2,cpu=0x100000c,minimum=16<<16):
    command=struct.pack('<6I',0x32,24,platform,minimum,(18<<16)|(5<<8),0)
    return struct.pack('<8I',0xfeedfacf,cpu,0,2,1,len(command),0,0)+command

class IPAPackageTests(unittest.TestCase):
    def package(self,root,*,version='0.1.10',mode=0o100755,executable=None,extra=None,manifest=b'{"test":true}'):
        path=root/'app.ipa';info={'CFBundleExecutable':'PortLab','CFBundlePackageType':'APPL','CFBundleIdentifier':'org.example.portlab',
            'CFBundleShortVersionString':version,'CFBundleVersion':'11','MinimumOSVersion':'16.0','CFBundleSupportedPlatforms':['iPhoneOS']}
        with zipfile.ZipFile(path,'w') as z:
            prefix='Payload/PortLab.app/'
            z.writestr(prefix+'Info.plist',plistlib.dumps(info));z.writestr(prefix+'DczlrData.manifest.json',manifest)
            entry=zipfile.ZipInfo(prefix+'PortLab');entry.create_system=3;entry.external_attr=mode<<16
            z.writestr(entry,binary() if executable is None else executable)
            if extra:z.writestr(extra,b'fixture')
        return path
    def test_device_bundle_version_permissions_and_manifest_are_checked(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);manifest=root/'manifest.json';manifest.write_bytes(b'{"test":true}')
            report=inspect(self.package(root),manifest,'0.1.10','11')
            self.assertEqual(report['architecture'],'arm64');self.assertEqual(report['platform'],'iOS')
            self.assertEqual(report['minimum_os'],(16,0,0));self.assertEqual(report['zip_crc'],'passed')
            self.assertEqual(len(report['sha256']),64)
    def test_simulator_architecture_and_truncated_executable_are_rejected(self):
        for data in (binary(platform=7),binary(cpu=0x1000007),b'MZfixture',binary()[:-1]):
            with self.assertRaises(ValueError):macho_device(data)
    def test_wrong_version_missing_execute_permission_or_modified_manifest_fail(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);manifest=root/'manifest.json';manifest.write_bytes(b'{"test":true}')
            for change in ({'version':'0.1.9'},{'mode':0o100644},{'manifest':b'changed'}):
                with self.assertRaises(ValueError):inspect(self.package(root,**change),manifest,'0.1.10','11')
    def test_traversal_and_bundled_game_payload_are_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);manifest=root/'manifest.json';manifest.write_bytes(b'{"test":true}')
            for entry in ('../escape','Payload/PortLab.app/Data/RPP_02.pp','Payload/PortLab.app/part.dczdata'):
                with self.assertRaises(ValueError):inspect(self.package(root,extra=entry),manifest,'0.1.10','11')
    def test_plist_and_macho_deployment_targets_must_match(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);manifest=root/'manifest.json';manifest.write_bytes(b'{"test":true}')
            path=self.package(root,executable=binary(minimum=17<<16))
            with self.assertRaises(ValueError):inspect(path,manifest,'0.1.10','11')
if __name__=='__main__':unittest.main()
