"""Verify exact-frame generated startup PNGs without third-party packages."""
import struct
import zlib


def decode(data):
    if data[:8]!=b'\x89PNG\r\n\x1a\n':raise ValueError('Invalid PNG signature')
    at=8;payload=bytearray();header=None;ended=False
    while at+12<=len(data):
        size=struct.unpack_from('>I',data,at)[0]
        if size>len(data)-at-12:raise ValueError('Truncated PNG chunk')
        kind=data[at+4:at+8];body=data[at+8:at+8+size]
        crc=struct.unpack_from('>I',data,at+8+size)[0]
        if zlib.crc32(kind+body)&0xffffffff!=crc:raise ValueError('PNG CRC differs')
        if kind==b'IHDR':
            if header is not None or size!=13:raise ValueError('Invalid PNG header')
            header=struct.unpack('>IIBBBBB',body)
        elif kind==b'IDAT':payload.extend(body)
        elif kind==b'IEND':ended=True;break
        at+=size+12
    if not ended or header is None:raise ValueError('PNG framing incomplete')
    width,height,depth,color,compression,filtering,interlace=header
    if not (0<width<=4096 and 0<height<=4096) or depth!=8 or color not in (2,6) or compression or filtering or interlace:
        raise ValueError('PNG profile outside RGB/RGBA8 gate')
    channels=3 if color==2 else 4;stride=width*channels;expected=(stride+1)*height
    decoder=zlib.decompressobj();raw=decoder.decompress(payload,expected+1)
    if len(raw)!=expected or not decoder.eof or decoder.unused_data:raise ValueError('PNG pixel stream differs from dimensions')
    out=bytearray(stride*height);previous=bytearray(stride);source=0
    for y in range(height):
        method=raw[source];source+=1
        if method>4:raise ValueError('Unknown PNG scanline filter')
        row=bytearray(raw[source:source+stride]);source+=stride
        for i in range(stride):
            left=row[i-channels] if i>=channels else 0;above=previous[i];corner=previous[i-channels] if i>=channels else 0
            predictor=0
            if method==1:predictor=left
            elif method==2:predictor=above
            elif method==3:predictor=(left+above)//2
            elif method==4:
                p=left+above-corner;distances=(abs(p-left),abs(p-above),abs(p-corner))
                predictor=(left,above,corner)[distances.index(min(distances))]
            row[i]=(row[i]+predictor)&255
        out[y*stride:(y+1)*stride]=row;previous=row
    return width,height,channels,bytes(out)


def verify(first,second):
    results=[]
    for index,data in enumerate((first,second)):
        width,height,channels,pixels=decode(data);matched=0
        for x_fraction in (.4,.5,.6):
            for y_fraction in (.4,.5,.6):
                x=int(width*x_fraction);y=int(height*y_fraction);at=(y*width+x)*channels
                r,g,b=pixels[at:at+3]
                correct=b>r+70 and b>g+25 if index==0 else r>b+70 and r>g+25
                matched+=bool(correct)
        if matched!=9:raise ValueError(f'Generated card {index} pixel color profile does not match its exact-frame capture')
        results.append({'card':index,'width':width,'height':height,'matched_center_samples':matched})
    return {'method':'native GPU readback saved on each stable card frame; generated color profile check',
            'cards':results,'original_gpu_equivalence':'not established'}
