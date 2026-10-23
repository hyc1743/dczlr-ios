import ctypes as C
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,ScriptRecord


class NativeScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

    def find(self,data,frame=0,cursor=0):
        out=ScriptRecord()
        self.assertEqual(self.lib.dc_script_find(data,len(data),cursor,frame,C.byref(out)),0)
        return out

    def test_opaque_control_header_speaker_body_and_duplicate_cursor(self):
        data=b'#bgm-test\r\n#T0000#C01#P00000\r\nSpeaker\r\nSelf-authored text.\r\n$END\r\n#T0000\nAgain\nSecond record.\n$END'
        first=self.find(data)
        self.assertEqual(data[first.header.offset:first.header.offset+first.header.length],b'#C01#P00000')
        self.assertEqual(data[first.speaker.offset:first.speaker.offset+first.speaker.length],b'Speaker')
        self.assertEqual(data[first.body.offset:first.body.offset+first.body.length],b'Self-authored text.\r\n')
        second=self.find(data,cursor=first.next_offset)
        self.assertGreater(second.marker_offset,first.marker_offset)
        self.assertEqual(data[second.speaker.offset:second.speaker.offset+second.speaker.length],b'Again')

    def test_partial_input_invalid_profiles_and_failure_atomicity(self):
        data=b'#T0001\nName\nBody$END';out=ScriptRecord();C.memset(C.byref(out),0xa5,C.sizeof(out));before=bytes(out)
        for length in range(6,len(data)):
            self.assertEqual(self.lib.dc_script_find(data,length,0,1,C.byref(out)),3)
            self.assertEqual(bytes(out),before)
        self.assertEqual(self.lib.dc_script_find(data,len(data),0,2,C.byref(out)),6)
        self.assertEqual(self.lib.dc_script_find(data,len(data),len(data)+1,1,C.byref(out)),4)
        for bad in (b'#T0001\rName\nBody$END',b'#T0001\nName\nBody\0$END'):
            self.assertEqual(self.lib.dc_script_find(bad,len(bad),0,1,C.byref(out)),3)
        self.assertEqual(bytes(out),before)

    def test_encoded_text_stays_opaque_and_source_overlap_is_rejected(self):
        data=b'#T9999\n\x82\xa0\n\x82\xa2$END';out=self.find(data,9999)
        self.assertEqual(data[out.body.offset:out.body.offset+out.body.length],b'\x82\xa2')
        source=C.create_string_buffer(data)
        self.assertEqual(self.lib.dc_script_find(source,len(data),0,9999,C.cast(source,C.POINTER(ScriptRecord))),1)
        large=b'#T0000\n'+b'x'*33+b'\nBody$END'
        self.assertEqual(self.lib.dc_script_find(large,len(large),0,0,C.byref(out)),4)


if __name__=='__main__':unittest.main()
