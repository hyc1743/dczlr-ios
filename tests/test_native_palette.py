import hashlib
import json
from pathlib import Path
import sys
import unittest
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from palette_cases import cases,native_result


class NativePaletteTests(unittest.TestCase):
    def test_windows_gdi_palette_reference(self):
        reference=json.loads((ROOT/'tests/fixtures/palette-gdi-vectors.json').read_text())
        digest=hashlib.sha256();count=0
        for case in cases():
            actual=native_result(case)
            digest.update((json.dumps({**case,'output':actual},sort_keys=True,separators=(',',':'))+'\n').encode());count+=1
        self.assertEqual(count,reference['cases']);self.assertEqual(digest.hexdigest(),reference['output_sha256'])


if __name__=='__main__':unittest.main()
