"""Upload every admitted standalone/XX texture and compare GPU point samples.

No image payloads are exported. This verifies texture transport and basic
sampling/alpha, not original game lighting, effects, scene choices or gameplay.
The caller supplies a shared library built from dc_vk_sprite.c and shaders.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
from native_core import PPArchive,XXModel,decode_image

class Config(C.Structure):
    _fields_=[(n,C.c_uint32) for n in ('width','height','max_textures','filter','validation')]+[
        ('vert',C.POINTER(C.c_uint32)),('vert_size',C.c_size_t),('frag',C.POINTER(C.c_uint32)),('frag_size',C.c_size_t),('layer',C.c_void_p)]
class Pose(C.Structure):
    _fields_=[(n,C.c_float) for n in ('width','height','x','y','z','origin_x','origin_y','scale_x','scale_y','alpha','rotation','red','green','blue','u0','u1','v0','v1')]
class Draw(C.Structure):
    _fields_=[('pose',Pose),('texture',C.c_size_t)]+[(n,C.c_uint8) for n in ('blend','hidden','point','software')]

def audit(data,renderer,shaders,output):
    vk=C.CDLL(str(renderer.resolve()))
    vk.dc_vk_sprite_create.argtypes=[C.POINTER(Config),C.POINTER(C.c_void_p),C.c_char_p,C.c_size_t]
    vk.dc_vk_sprite_upload.argtypes=[C.c_void_p,C.c_uint32,C.c_uint32,C.c_void_p,C.c_size_t,C.POINTER(C.c_size_t)]
    vk.dc_vk_sprite_render.argtypes=[C.c_void_p,C.POINTER(Draw),C.c_size_t,C.c_void_p,C.c_void_p,C.c_size_t]
    vk.dc_vk_sprite_remove_texture.argtypes=[C.c_void_p,C.c_size_t]
    vk.dc_vk_sprite_destroy.argtypes=[C.c_void_p]
    vk.dc_vk_sprite_error.argtypes=[C.c_void_p];vk.dc_vk_sprite_error.restype=C.c_char_p
    code=[]
    for stage in ('vert','frag'):
        b=(shaders/('sprite.'+stage+'.spv')).read_bytes();code.append((C.c_uint32*(len(b)//4)).from_buffer_copy(b))
    cfg=Config(8,8,1,1,0,code[0],C.sizeof(code[0]),code[1],C.sizeof(code[1]),None)
    handle=C.c_void_p();error=C.create_string_buffer(1024)
    status=vk.dc_vk_sprite_create(C.byref(cfg),C.byref(handle),error,len(error))
    if status:raise RuntimeError(error.value.decode(errors='replace'))
    def check(status):
        if status:raise RuntimeError(f'Vulkan status {status}: {vk.dc_vk_sprite_error(handle)!r}')
    rows=[];excluded=[];seen={};clear=bytes((13,29,47,255));total=0
    def verify(label,info,rgba):
        nonlocal total
        digest=hashlib.sha256(rgba).hexdigest();key=(info.width,info.height,digest)
        row={'asset':label,'width':info.width,'height':info.height,'rgba_sha256':digest}
        if key in seen:
            row.update(status='same_decoded_texture',verified_by=seen[key]);rows.append(row);return
        texture=C.c_size_t();check(vk.dc_vk_sprite_upload(handle,info.width,info.height,rgba,len(rgba),C.byref(texture)))
        try:
            draws=(Draw*16)();expected=[]
            for j in range(4):
                for i in range(4):
                    x=min(info.width-1,int((i+.5)*info.width/4));y=min(info.height-1,int((j+.5)*info.height/4))
                    u,v=(x+.5)/info.width,(y+.5)/info.height
                    draws[j*4+i]=Draw(Pose(width=2,height=2,x=i*2,y=j*2,z=.5,scale_x=1,scale_y=1,
                        alpha=1,red=1,green=1,blue=1,u0=u,u1=u,v0=v,v1=v),texture.value,3,0,1,0)
                    p=rgba[(y*info.width+x)*4:(y*info.width+x+1)*4];a=p[3]
                    expected.append([(p[c]*a+clear[c]*(255-a))/255 for c in range(3)])
            output_pixels=C.create_string_buffer(8*8*4)
            check(vk.dc_vk_sprite_render(handle,draws,16,clear,output_pixels,len(output_pixels)))
            actual=output_pixels.raw;largest=0
            for j in range(4):
                for i in range(4):
                    at=((j*2)*8+i*2)*4
                    for c in range(3):largest=max(largest,abs(actual[at+c]-expected[j*4+i][c]))
            row.update(status='gpu_samples_match' if largest<=2 else 'gpu_samples_differ',samples=16,max_rgb_error=round(largest,6))
            if largest<=2:seen[key]=label
            total+=1
        finally:check(vk.dc_vk_sprite_remove_texture(handle,texture.value))
        rows.append(row)
    try:
        for archive in sorted(data.glob('*.pp')):
            try:pp=PPArchive(archive)
            except ValueError as e:
                excluded.append({'archive':archive.name,'reason':str(e)});continue
            with pp:
                for index in range(pp.count):
                    name=pp.entry(index).name_bytes.decode('ascii');suffix=Path(name).suffix.lower()
                    fmt={'.bmp':1,'.tga':2,'.ema':3}.get(suffix)
                    label=archive.name+'/'+name
                    try:
                        if fmt:
                            info,rgba=decode_image(pp.read(index),fmt);verify(label,info,rgba)
                        elif suffix=='.xx':
                            with XXModel(pp.read(index)) as model:
                                for tex in range(model.info().textures):
                                    info,rgba=model.image(tex);verify(label+f'/texture-{tex}',info,rgba)
                    except (RuntimeError,ValueError) as e:rows.append({'asset':label,'status':'failed','reason':str(e)})
            print(json.dumps({'archive':archive.name,'asset_references':len(rows),'unique_gpu_textures':total}),flush=True)
    finally:vk.dc_vk_sprite_destroy(handle)
    failed=[r for r in rows if r['status'] not in ('gpu_samples_match','same_decoded_texture')]
    report={'method':'native decode -> Vulkan upload -> 16 point samples -> RGB alpha blend comparison',
        'renderer_sha256':hashlib.sha256(renderer.read_bytes()).hexdigest(),'asset_references':len(rows),'unique_gpu_textures':total,
        'failed':len(failed),'excluded_archives':excluded,'assets':rows,'payload_exported':False,
        'original_scene_effects_lighting_and_gameplay':'not established','apple_gpu':'not exercised by local Windows backend'}
    output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='assets'}));return not failed

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--data',type=Path,required=True);p.add_argument('--renderer',type=Path,required=True)
    p.add_argument('--shaders',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();raise SystemExit(0 if audit(a.data,a.renderer,a.shaders,a.output) else 1)
