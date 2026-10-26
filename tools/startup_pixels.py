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


def verify_intro(data):
    width,height,channels,pixels=decode(data);matched=0
    for fx in (.4,.5,.6):
        for fy in (.4,.5,.6):
            at=(int(height*fy)*width+int(width*fx))*channels;r,g,b=pixels[at:at+3]
            matched+=g>r+40 and g>b+25
    if matched!=9:raise ValueError('Generated intro background is absent from exact GPU capture')
    scale=min(width/1024,height/768);ox=(width-1024*scale)/2;oy=(height-768*scale)/2
    white=0
    for y in range(max(0,int(oy+652*scale)),min(height,int(oy+700*scale))):
        for x in range(max(0,int(ox+135*scale)),min(width,int(ox+400*scale))):
            at=(y*width+x)*channels
            white+=min(pixels[at:at+3])>=210
    if white<max(20,int(50*scale*scale)):raise ValueError('Generated intro body text is absent from exact GPU capture')
    return {'method':'native GPU readback after record0 fade; generated background and text-region pixel presence',
        'width':width,'height':height,'matched_background_samples':matched,'bright_body_pixels':white,
        'font_or_character_identity':'requires screenshot inspection; no OCR or original-font equivalence claim'}


def verify_skin(data):
    width,height,channels,pixels=decode(data);red=0
    for y in range(int(height*.35),int(height*.65)):
        for x in range(int(width*.2),int(width*.8)):
            at=(y*width+x)*channels;r,g,b=pixels[at:at+3]
            red+=r>g+35 and r>b+25
    if red<max(64,int(width*height*.0001)):raise ValueError('Generated textured skin surface is absent from exact GPU capture')
    scale=min(width/1024,height/768);ox=(width-1024*scale)/2;oy=(height-768*scale)/2
    left=max(0,int(ox)-2);right=min(width,int(ox+1024*scale+1)+2)
    top=max(0,int(oy)-2);bottom=min(height,int(oy+768*scale+1)+2);outside=0
    for y in range(height):
        for x in range(width):
            if left<=x<right and top<=y<bottom:continue
            at=(y*width+x)*channels;outside+=max(pixels[at:at+3])>2
    if outside:raise ValueError('Geometry escaped the letterboxed game viewport')
    return {'method':'exact GPU readback after changed world-space skin sample; generated textured-surface color presence',
        'width':width,'height':height,'red_surface_pixels':red,'nonblack_letterbox_pixels':outside,
        'original_skin_or_image_equivalence':'not established'}


def verify_gameplay_actor(data):
    """Bounded visual gate for the deterministic first-map blue-outfit actor.

    Event markers do not prove that geometry survived occlusion. Check that the
    known outfit occupies a character-sized screen area with plausible height.
    This is a visibility check, not an original-game image-equivalence claim.
    """
    width,height,channels,pixels=decode(data)
    scale=min(width/1024,height/768);ox=(width-1024*scale)/2;oy=(height-768*scale)/2
    hits=0;skin=0;first=height;last=-1
    for y in range(int(oy+100*scale),min(height,int(oy+740*scale))):
        for x in range(max(0,int(ox+280*scale)),min(width,int(ox+740*scale))):
            at=(y*width+x)*channels;r,g,b=pixels[at:at+3]
            # Grey-blue background silhouettes passed the former loose gate.
            # Require saturated outfit color and a separate skin-color region.
            if b>r+45 and g>r+25 and b>=g-8:
                hits+=1;first=min(first,y);last=max(last,y)
            if r>g+12 and g>b+10 and r>120:skin+=1
    area=1024*768*scale*scale
    if not area*.01<hits<area*.25 or skin<area*.003 or last-first<160*scale:
        raise ValueError(f'First gameplay actor is absent, occluded or fragmented: outfit_pixels={hits}, skin_pixels={skin}, span={last-first}')
    return {'method':'first native GPU frame; bounded saturated outfit area, skin region and height',
            'outfit_pixels':hits,'skin_pixels':skin,'vertical_span':last-first,'width':width,'height':height,
            'original_image_equivalence':'not established'}
