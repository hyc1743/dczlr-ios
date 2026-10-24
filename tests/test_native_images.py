"""Pixel behavior and hostile-input tests for the actual portable C decoder."""
import ctypes as C
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from native_core import ImageInfo, decode_image, library

RED = bytes((255, 0, 0, 255))
GREEN = bytes((0, 255, 0, 255))
BLUE = bytes((0, 0, 255, 255))
WHITE = bytes((255, 255, 255, 255))


def tga(width, height, pixels, depth=24, descriptor=0x20, rle=False, image_id=b""):
    header = struct.pack("<BBBHHBHHHHBB", len(image_id), 0, 10 if rle else 2,
                         0, 0, 0, 0, 0, width, height, depth, descriptor)
    return header + image_id + pixels


def bmp(width, height, pixels):
    return (struct.pack("<2sIHHI", b"BM", 54 + len(pixels), 0, 0, 54) +
            struct.pack("<IiiHHIIiiII", 40, width, height, 1, 24, 0, len(pixels), 0, 0, 0, 0) + pixels)


def indexed_bmp(width,height,pixels,palette,used=None):
    table=b''.join(bytes((color[2],color[1],color[0],color[3])) for color in palette)
    offset=54+len(table)
    return struct.pack('<2sIHHI',b'BM',offset+len(pixels),0,0,offset)+struct.pack('<IiiHHIIiiII',
        40,width,height,1,8,0,0,0,0,len(palette) if used is None else used,0)+table+pixels


class NativeImageTests(unittest.TestCase):
    def test_indexed_bmp_palette_row_orientation_and_padding(self):
        palette=[(255,0,0,19),(0,255,0,0),(0,0,255,255)]
        top=bytes((0,1,2,250,2,1,0,251));bottom=top[4:]+top[:4]
        expected=RED+GREEN+BLUE+BLUE+GREEN+RED
        for height,pixels in ((-2,top),(2,bottom)):
            data=indexed_bmp(3,height,pixels,palette)
            self.assert_pixels(data,1,expected,(3,2))
            embedded=b'\0\0'+data[2:]
            self.assert_pixels(embedded,4,expected,(3,2))
            self.assert_pixels(struct.pack('<II',3,2)+b'.bmp\0'+embedded,3,expected,(3,2))
        default=[(i,i,i,0) for i in range(256)]
        self.assert_pixels(indexed_bmp(1,1,bytes((255,99,99,99)),default,used=0),1,WHITE,(1,1))

    def test_indexed_palette_and_late_index_fail_before_writing(self):
        palette=[(255,0,0,0),(0,255,0,0)]
        valid=indexed_bmp(2,-2,bytes((0,1,250,250,1,0,251,251)),palette)
        for used in (0,3,257):
            changed=bytearray(valid);struct.pack_into('<I',changed,46,used)
            self.assert_rejected(bytes(changed),1)
        bad=bytearray(valid);bad[-3]=2
        self.assert_rejected(bytes(bad),1)
        for length in range(len(valid)):self.assert_rejected(valid[:length],1)
    def assert_pixels(self, data, format, expected, size):
        info, pixels = decode_image(data, format)
        self.assertEqual((info.width, info.height), size)
        self.assertEqual(info.rgba_bytes, len(expected))
        self.assertEqual(pixels, expected)

    def assert_rejected(self, data, format, capacity=64):
        output = C.create_string_buffer(b"\xa5" * 64, 64)
        info = ImageInfo(7, 9, 11)
        status = library().dc_image_decode(data, len(data), format, output, capacity, C.byref(info))
        self.assertNotEqual(status, 0)
        self.assertEqual(output.raw, b"\xa5" * 64)
        self.assertEqual((info.width, info.height, info.rgba_bytes), (7, 9, 11))

    def test_bmp_both_row_directions_and_padding(self):
        # Two one-pixel rows, each padded to four bytes. Padding is not color.
        self.assert_pixels(bmp(1, 2, b"\xff\0\0\x77\0\0\xff\x88"), 1, RED + BLUE, (1, 2))
        self.assert_pixels(bmp(1, -2, b"\0\0\xff\x77\xff\0\0\x88"), 1, RED + BLUE, (1, 2))

    def test_tga_four_origins(self):
        # The expected display is R G / B W for every storage orientation.
        cases = [(0x20, (RED, GREEN, BLUE, WHITE)), (0, (BLUE, WHITE, RED, GREEN)),
                 (0x30, (GREEN, RED, WHITE, BLUE)), (0x10, (WHITE, BLUE, GREEN, RED))]
        for descriptor, colors in cases:
            data = b"".join(bytes((c[2], c[1], c[0])) for c in colors)
            with self.subTest(descriptor=descriptor):
                self.assert_pixels(tga(2, 2, data, descriptor=descriptor, image_id=b"test"),
                                   2, RED + GREEN + BLUE + WHITE, (2, 2))

    def test_tga_alpha_and_rle_packets_crossing_rows(self):
        half_red = bytes((255, 0, 0, 127))
        raw = b"\0\0\xff\x7f\xff\0\0\0"
        self.assert_pixels(tga(2, 1, raw, depth=32, descriptor=0x28), 2,
                           half_red + bytes((0, 0, 255, 0)), (2, 1))
        # A three-pixel repeated packet crosses a two-pixel row, then a raw packet.
        packets = b"\x82\0\0\xff\x02\0\xff\0\xff\0\0\xff\xff\xff"
        self.assert_pixels(tga(2, 3, packets, rle=True), 2,
                           RED * 3 + GREEN + BLUE + WHITE, (2, 3))

    def test_ema_tags_and_embedded_dimensions(self):
        for tag, image in [(b".bmp\0", bmp(1, 1, b"\0\0\xff\0")),
                           (b".tga\0", tga(1, 1, b"\0\0\xff"))]:
            with self.subTest(tag=tag):
                payload = struct.pack("<II", 1, 1) + tag + image
                self.assert_pixels(payload, 3, RED, (1, 1))
                self.assert_rejected(struct.pack("<II", 2, 1) + payload[8:], 3)
                for length in range(len(payload)):
                    self.assert_rejected(payload[:length], 3)
        embedded = b"\0\0" + bmp(1, 1, b"\0\0\xff\0")[2:]
        self.assert_pixels(struct.pack("<II", 1, 1) + b".bmp\0" + embedded, 3, RED, (1, 1))
        self.assert_rejected(embedded, 1)
        self.assert_rejected(struct.pack("<II", 1, 1) + b".bmp\0XY" + embedded[2:], 3)

    def test_truncation_and_bad_rle_preserve_destination(self):
        images = [(bmp(1, 1, b"\0\0\xff\0"), 1),
                  (tga(1, 1, b"\0\0\xff"), 2),
                  (tga(2, 1, b"\x81\0\0\xff", rle=True), 2)]
        for image, format in images:
            for length in range(len(image)):
                with self.subTest(format=format, length=length):
                    self.assert_rejected(image[:length], format)
        self.assert_rejected(tga(1, 1, b"\x81\0\0\xff", rle=True), 2)
        self.assert_rejected(tga(1, 1, b"\x00\0\0", rle=True), 2)

    def test_unknown_profiles_dimensions_and_capacity(self):
        valid_tga = tga(1, 1, b"\0\0\xff")
        valid_bmp = bmp(1, 1, b"\0\0\xff\0")
        for offset, value in [(1, 1), (2, 3), (16, 16), (17, 0x60)]:
            changed = bytearray(valid_tga); changed[offset] = value
            self.assert_rejected(bytes(changed), 2)
        for offset, value in [(0, 0), (10, 53), (14, 108), (26, 2), (28, 32), (30, 1)]:
            changed = bytearray(valid_bmp); changed[offset] = value
            self.assert_rejected(bytes(changed), 1)
        self.assert_rejected(tga(0, 1, b""), 2)
        self.assert_rejected(bmp(0, 1, b""), 1)
        self.assert_rejected(bmp(-1, 1, b""), 1)
        self.assert_rejected(bmp(1, -2147483648, b""), 1)
        self.assert_rejected(bmp(2147483647, 2147483647, b""), 1)
        self.assert_rejected(valid_tga, 2, capacity=3)
        self.assert_rejected(valid_tga, 999)
        self.assert_rejected(struct.pack("<II", 1, 1) + b".png\0" + valid_tga, 3)
        with self.assertRaises(ValueError):
            decode_image(valid_tga, 2, max_bytes=3)

    def test_arguments_overlap_and_destination_guards(self):
        lib = library(); info = ImageInfo()
        self.assertNotEqual(lib.dc_image_probe(None, 0, 2, C.byref(info)), 0)
        data = tga(1, 1, b"\0\0\xff")
        self.assertNotEqual(lib.dc_image_probe(data, len(data), 2, None), 0)
        self.assertNotEqual(lib.dc_image_decode(data, len(data), 2, None, 4, None), 0)
        buffer = C.create_string_buffer(data, len(data))
        self.assertNotEqual(lib.dc_image_decode(buffer, len(data), 2, buffer, 4, None), 0)
        self.assertEqual(buffer.raw, data)
        guarded = C.create_string_buffer(b"\xaa" * 12, 12)
        self.assertEqual(lib.dc_image_decode(data, len(data), 2, C.byref(guarded, 4), 4, None), 0)
        self.assertEqual(guarded.raw, b"\xaa" * 4 + RED + b"\xaa" * 4)


if __name__ == "__main__":
    unittest.main()
