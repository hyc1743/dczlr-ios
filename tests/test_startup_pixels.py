import struct
import sys
from pathlib import Path
import unittest
import zlib

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from startup_pixels import decode,verify,verify_intro,verify_skin


def png(color,width=8,height=8):
    def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
    row=bytes((*color,255))*width
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+row)*height))+chunk(b'IEND',b'')


class StartupPixelTests(unittest.TestCase):
    def test_skin_color_gate_does_not_accept_a_card_or_black_frame(self):
        # The color gate only proves generated surface presence, not pose or
        # bone identity; the native change/presentation marker is separate.
        for data in (png((20,110,180)),png((0,0,0))):
            with self.assertRaises(ValueError):verify_skin(data)
        self.assertGreater(verify_skin(png((255,80,40),64,64))['red_surface_pixels'],64)
    def test_intro_requires_background_and_body_region_pixels(self):
        def sample(body):
            def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
            width,height=320,240;pixels=bytearray(bytes((30,130,70,255))*width*height)
            if body:
                for y in range(207,213):
                    for x in range(50,80):pixels[(y*width+x)*4:(y*width+x)*4+4]=bytes((255,255,255,255))
            raw=b''.join(b'\0'+pixels[y*width*4:(y+1)*width*4] for y in range(height))
            return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')
        self.assertEqual(verify_intro(sample(True))['matched_background_samples'],9)
        with self.assertRaises(ValueError):verify_intro(sample(False))

    def test_correct_order_and_swapped_or_repeated_cards(self):
        first,second=png((20,110,180)),png((180,80,20))
        self.assertEqual(decode(first)[:3],(8,8,4))
        self.assertEqual([r['matched_center_samples'] for r in verify(first,second)['cards']],[9,9])
        for a,b in ((second,first),(second,second),(first,first),(png((0,0,0)),second)):
            with self.assertRaises(ValueError):verify(a,b)

    def test_corrupt_pixels_or_truncated_png_never_certify_a_stage(self):
        source=png((20,110,180));bad=bytearray(source);bad[40]^=1
        for data in (source[:7],source[:-12],bytes(bad)):
            with self.assertRaises(ValueError):decode(data)


if __name__=='__main__':unittest.main()
