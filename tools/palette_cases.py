"""Self-authored indexed BMPs: palette size, row origin and scanline padding."""
import struct
from itertools import product
from native_core import decode_image


def cases():
    for width,height,count in product((1,2,3,4,7,17),(-3,-1,1,3),(2,3,16,46,256)):
        palette=b''.join(bytes(((i*73+11)&255,(i*29+7)&255,(i*37+3)&255,(i*11)&255)) for i in range(count))
        stride=(width+3)&~3;pixels=bytearray()
        for y in range(abs(height)):
            pixels+=bytes((x*7+y*13)%count for x in range(width))+b'\xff'*(stride-width)
        offset=54+len(palette);used=0 if count==256 else count
        data=struct.pack('<2sIHHI',b'BM',offset+len(pixels),0,0,offset)
        data+=struct.pack('<IiiHHIIiiII',40,width,height,1,8,0,0,0,0,used,0)+palette+pixels
        yield {'width':width,'height':height,'palette_count':count,'bmp_hex':data.hex()}


def native_result(case):
    info,rgba=decode_image(bytes.fromhex(case['bmp_hex']),1)
    return {'width':info.width,'height':info.height,'rgba_hex':rgba.hex()}
