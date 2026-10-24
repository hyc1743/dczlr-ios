"""Windows GDI indexed-DIB reference. No game executable or window is used."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from palette_cases import cases,native_result


class WindowsDIB:
    def __init__(self):
        self.gdi=C.WinDLL('gdi32',use_last_error=True)
        self.gdi.CreateCompatibleDC.argtypes=[C.c_void_p];self.gdi.CreateCompatibleDC.restype=C.c_void_p
        self.gdi.CreateDIBSection.argtypes=[C.c_void_p,C.c_void_p,C.c_uint,C.POINTER(C.c_void_p),C.c_void_p,C.c_uint]
        self.gdi.CreateDIBSection.restype=C.c_void_p
        self.gdi.GetDIBits.argtypes=[C.c_void_p,C.c_void_p,C.c_uint,C.c_uint,C.c_void_p,C.c_void_p,C.c_uint]
        self.gdi.GetDIBits.restype=C.c_int
        self.gdi.DeleteObject.argtypes=[C.c_void_p];self.gdi.DeleteObject.restype=C.c_int
        self.gdi.DeleteDC.argtypes=[C.c_void_p];self.gdi.DeleteDC.restype=C.c_int

    def decode(self,data):
        if len(data)<54 or struct.unpack_from('<I',data,14)[0]!=40 or struct.unpack_from('<H',data,28)[0]!=8 or struct.unpack_from('<I',data,30)[0]:
            raise ValueError('Reference requires uncompressed indexed BITMAPINFOHEADER input')
        width,height=struct.unpack_from('<ii',data,18);offset=struct.unpack_from('<I',data,10)[0]
        if not (0<width<=4096 and 0<abs(height)<=4096):raise ValueError('Reference dimensions outside bounded profile')
        stride=(width+3)&~3;size=stride*abs(height)
        if offset<54 or offset>len(data) or size>len(data)-offset:raise ValueError('Truncated reference pixel span')
        info=C.create_string_buffer(data[14:offset]);bits=C.c_void_p();dc=self.gdi.CreateCompatibleDC(None)
        if not dc:raise RuntimeError('CreateCompatibleDC failed')
        bitmap=None
        try:
            bitmap=self.gdi.CreateDIBSection(dc,info,0,C.byref(bits),None,0)
            if not bitmap or not bits:raise RuntimeError('CreateDIBSection failed')
            C.memmove(bits,data[offset:offset+size],size)
            destination=C.create_string_buffer(width*abs(height)*4)
            output_info=C.create_string_buffer(struct.pack('<IiiHHIIiiII',40,width,-abs(height),1,32,0,len(destination),0,0,0,0))
            if self.gdi.GetDIBits(dc,bitmap,0,abs(height),destination,output_info,0)!=abs(height):raise RuntimeError('GetDIBits did not return all rows')
            bgra=destination.raw;rgba=bytearray(len(bgra))
            for i in range(0,len(bgra),4):rgba[i:i+4]=bytes((bgra[i+2],bgra[i+1],bgra[i],255))
            return {'width':width,'height':abs(height),'rgba_hex':rgba.hex()}
        finally:
            if bitmap:self.gdi.DeleteObject(bitmap)
            self.gdi.DeleteDC(dc)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--vectors',type=Path,required=True);args=p.parse_args()
    reference=WindowsDIB();digest=hashlib.sha256();count=0
    for case in cases():
        expected=reference.decode(bytes.fromhex(case['bmp_hex']));actual=native_result(case)
        if expected!=actual:raise ValueError(f'Native palette differs from GDI reference at case {count}')
        digest.update((json.dumps({**case,'output':expected},sort_keys=True,separators=(',',':'))+'\n').encode());count+=1
    report={'cases':count,'output_sha256':digest.hexdigest(),'reference':'Windows GDI CreateDIBSection/GetDIBits; alpha normalized opaque',
        'coverage':'self-authored 8-bit palettes, reserved bytes, colors-used/default256, both row origins and padding',
        'game_resources_used':False,'original_game_or_gpu_executed':False}
    for path in (args.output,args.vectors):path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report))


if __name__=='__main__':main()
