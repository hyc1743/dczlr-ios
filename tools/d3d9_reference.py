"""Windows NULLREF software-vertex reference; hidden window, no drawing/Present."""
import ctypes as C
import struct


class PresentParameters(C.Structure):
    _fields_=[(n,C.c_uint32) for n in ('width','height','format','count','multisample','quality','swap')]+[
        ('window',C.c_void_p)]+[(n,C.c_uint32) for n in ('windowed','depth','depth_format','flags','refresh','interval')]


class Viewport(C.Structure):
    _fields_=[(n,C.c_uint32) for n in ('x','y','width','height')]+[('min_z',C.c_float),('max_z',C.c_float)]


def method(pointer,index,result,*arguments):
    table=C.cast(pointer,C.POINTER(C.POINTER(C.c_void_p))).contents
    return C.WINFUNCTYPE(result,C.c_void_p,*arguments)(table[index])


def check(result,label):
    if result<0:raise RuntimeError(f'{label} failed: {result&0xffffffff:#x}')


class D3D9Reference:
    def __init__(self):
        self.window=self.interface=self.device=None;self.buffers=[];self.changed=set()
        self.user=C.WinDLL('user32',use_last_error=True);self.d3d=C.WinDLL('d3d9',use_last_error=True)
        self.user.CreateWindowExW.argtypes=[C.c_uint32,C.c_wchar_p,C.c_wchar_p,C.c_uint32]+[C.c_int]*4+[C.c_void_p]*4
        self.user.CreateWindowExW.restype=C.c_void_p
        self.user.DestroyWindow.argtypes=[C.c_void_p];self.user.DestroyWindow.restype=C.c_int
        self.d3d.Direct3DCreate9.argtypes=[C.c_uint32];self.d3d.Direct3DCreate9.restype=C.c_void_p
        try:
            self.window=self.user.CreateWindowExW(0,'STATIC','PortLab numeric reference',0,0,0,1,1,None,None,None,None)
            if not self.window:raise RuntimeError('Hidden reference window creation failed')
            self.interface=self.d3d.Direct3DCreate9(32)
            if not self.interface:raise RuntimeError('Direct3DCreate9 failed')
            create=method(self.interface,16,C.c_int32,C.c_uint32,C.c_uint32,C.c_void_p,C.c_uint32,C.POINTER(PresentParameters),C.POINTER(C.c_void_p))
            params=PresentParameters(width=1,height=1,count=1,swap=1,window=self.window,windowed=1)
            self.device=C.c_void_p();check(create(self.interface,0,4,self.window,0x22,C.byref(params),C.byref(self.device)),'CreateDevice NULLREF/SWVP')
            self.identity=struct.pack('<16f',*(1 if i%5==0 else 0 for i in range(16)))
            self.state(137,0);self.state(136,0);self.state(151,3);self.state(167,1)
            self.viewport=Viewport(0,0,100,100,0,1)
            check(method(self.device,47,C.c_int32,C.POINTER(Viewport))(self.device,C.byref(self.viewport)),'SetViewport')
            self.transform(2,self.identity);self.transform(3,self.identity)
        except Exception:
            self.close();raise

    def __enter__(self):return self
    def __exit__(self,*_):self.close()
    def close(self):
        for buffer in self.buffers:method(buffer,2,C.c_uint32)(buffer)
        self.buffers=[]
        if self.device:method(self.device,2,C.c_uint32)(self.device);self.device=None
        if self.interface:method(self.interface,2,C.c_uint32)(self.interface);self.interface=None
        if self.window:self.user.DestroyWindow(self.window);self.window=None

    def state(self,key,value):
        check(method(self.device,57,C.c_int32,C.c_uint32,C.c_uint32)(self.device,key,value),'SetRenderState')

    def transform(self,state,raw):
        matrix=C.create_string_buffer(raw)
        check(method(self.device,44,C.c_int32,C.c_uint32,C.c_void_p)(self.device,state,matrix),'SetTransform')

    def get_transform(self,state):
        matrix=(C.c_float*16)()
        check(method(self.device,45,C.c_int32,C.c_uint32,C.c_void_p)(self.device,state,matrix),'GetTransform')
        return bytes(matrix)

    def buffer(self,length,fvf):
        buffer=C.c_void_p()
        create=method(self.device,26,C.c_int32,C.c_uint32,C.c_uint32,C.c_uint32,C.c_uint32,C.POINTER(C.c_void_p),C.c_void_p)
        check(create(self.device,length,0x10,fvf,2,C.byref(buffer),None),'CreateVertexBuffer')
        self.buffers.append(buffer);return buffer

    def write_buffer(self,buffer,data):
        pointer=C.c_void_p()
        check(method(buffer,11,C.c_int32,C.c_uint32,C.c_uint32,C.POINTER(C.c_void_p),C.c_uint32)(buffer,0,len(data),C.byref(pointer),0),'VertexBuffer.Lock')
        try:C.memmove(pointer,data,len(data))
        finally:check(method(buffer,12,C.c_int32)(buffer),'VertexBuffer.Unlock')

    def read_buffer(self,buffer,length):
        pointer=C.c_void_p()
        check(method(buffer,11,C.c_int32,C.c_uint32,C.c_uint32,C.POINTER(C.c_void_p),C.c_uint32)(buffer,0,length,C.byref(pointer),0x10),'VertexBuffer.Lock read')
        try:return C.string_at(pointer,length)
        finally:check(method(buffer,12,C.c_int32)(buffer),'VertexBuffer.Unlock')

    def process(self,vertices,palette,fvf=0x111c):
        if fvf not in (0x112,0x111c):raise ValueError('Reference FVF outside admitted profile')
        stride=48 if fvf==0x111c else 32
        if not vertices or len(vertices)%stride:raise ValueError('Reference source records are truncated')
        count=len(vertices)//stride
        if count>1048576:raise ValueError('Reference vertex count outside bound')
        for index in self.changed-set(palette):self.transform(256+index,self.identity)
        for index,matrix in palette.items():self.transform(256+index,matrix)
        self.changed=set(palette)
        self.state(151,3 if fvf==0x111c else 0);self.state(167,int(fvf==0x111c))
        source=self.buffer(len(vertices),fvf);destination=self.buffer(count*16,4)
        self.write_buffer(source,vertices)
        check(method(self.device,89,C.c_int32,C.c_uint32)(self.device,fvf),'SetFVF')
        check(method(self.device,100,C.c_int32,C.c_uint32,C.c_void_p,C.c_uint32,C.c_uint32)(self.device,0,source,0,stride),'SetStreamSource')
        process=method(self.device,85,C.c_int32,C.c_uint32,C.c_uint32,C.c_uint32,C.c_void_p,C.c_void_p,C.c_uint32)
        check(process(self.device,0,0,count,destination,None,0),'ProcessVertices')
        raw=self.read_buffer(destination,count*16)
        check(method(self.device,100,C.c_int32,C.c_uint32,C.c_void_p,C.c_uint32,C.c_uint32)(self.device,0,None,0,0),'Unbind source')
        for buffer in (source,destination):method(buffer,2,C.c_uint32)(buffer);self.buffers.remove(buffer)
        return raw
