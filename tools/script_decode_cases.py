"""Self-authored parser records and fixed-width header controls."""
import ctypes as C
from itertools import product
from native_core import ScriptControl,ScriptDecoded


def cases():
    for newline,frame,preamble,header,speaker in product((b'\n',b'\r\n'),(0,7,9999),
        (b'',b'#cg-test\n#bgm-test\n#SE-test\n',b'#MS-test\n#cgblackout\n',
         b'#bg-other\n#bg-next\n',b'#cg-one\nignored\n#cg-two\n',
         b'#SE-first\n#bgm-missed\n',b'#CGignored\n#BGMOFF\n'),
        (b'',b'#C01#P00000',b'#C02A#P12345C',b'x#C03Bz#C04y',b'#P23456B#P45678',b'#C05C#C06'),
        (b'',b'Author',b'\x82\xa0')):
        prefix=b'skip$END'+newline
        data=prefix+preamble.replace(b'\n',newline)+f'#T{frame:04d}'.encode()+header+newline+speaker+newline+b'Self-authored '+b'\x82\xa2'+newline+b'$END'
        yield {'hex':data.hex(),'cursor':len(prefix),'frame':frame,'controls':[['#C',2],['#P',5]]}
    for n in (0,1,5,10,11):
        header=b''.join(f'@{i}!!'.encode() for i in range(n))
        data=b'#T0000'+header+b'\nAuthor\nBody$END'
        yield {'hex':data.hex(),'cursor':0,'frame':0,'controls':[[f'@{i}',2] for i in range(n)]}


def control_array(case):
    out=(ScriptControl*len(case['controls']))()
    for i,(key,n) in enumerate(case['controls']):
        for j,b in enumerate(key.encode()):out[i].key[j]=b
        out[i].parameter_bytes=n
    return out


def native_result(lib,case):
    data=bytes.fromhex(case['hex']);controls=control_array(case);out=ScriptDecoded()
    status=lib.dc_script_decode(data,len(data),case['cursor'],case['frame'],controls,len(controls),C.byref(out))
    if status:raise ValueError(f'Script decode rejected case: {status}, {case}')
    r=out.record
    return {'cursor':r.next_offset,'speaker':data[r.speaker.offset:r.speaker.offset+r.speaker.length].hex(),
            'body':data[r.body.offset:r.body.offset+r.body.length].hex(),
            **{n:bytes(getattr(out,n)).hex() for n in ('background','music','sound','message')},
            'controls':bytes(out.controls).hex()}
