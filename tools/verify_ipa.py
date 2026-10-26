"""Inspect the actual unsigned device IPA before publishing it.

Checks packaging and Mach-O metadata, not signing or device execution.
Mach-O constants/layout follow Apple's mach-o/loader.h and mach/machine.h.
"""
import argparse
import hashlib
import json
from pathlib import Path,PurePosixPath
import plistlib
import stat
import struct
import zipfile

def version(value):
    parts=[int(v) for v in str(value).split('.')]
    if not 1<=len(parts)<=3:raise ValueError('Invalid OS version')
    return tuple(parts+[0]*(3-len(parts)))

def macho_device(data):
    if len(data)<32:raise ValueError('Truncated executable')
    magic,cpu,subtype,kind,count,size,flags,reserved=struct.unpack_from('<8I',data)
    if (magic,cpu,kind)!=(0xfeedfacf,0x100000c,2):raise ValueError('Expected thin ARM64 Mach-O executable')
    if not 0<count<=4096 or size>len(data)-32:raise ValueError('Invalid Mach-O load commands')
    at=32;end=32+size;build=None;signature=False
    for _ in range(count):
        if at+8>end:raise ValueError('Truncated load command')
        cmd,length=struct.unpack_from('<2I',data,at)
        if length<8 or length%8 or at+length>end:raise ValueError('Invalid load command size')
        if cmd==0x32:
            if length<24 or build is not None:raise ValueError('Invalid build version command')
            platform,minimum,sdk,tools=struct.unpack_from('<4I',data,at+8)
            if platform!=2 or length!=24+tools*8:raise ValueError('Executable is not built for iOS devices')
            decode=lambda v:(v>>16,(v>>8)&255,v&255)
            build={'platform':'iOS','architecture':'arm64','minimum_os':decode(minimum),'sdk':decode(sdk)}
        if cmd==0x1d:
            if length<16:raise ValueError('Invalid code signature command')
            offset,amount=struct.unpack_from('<2I',data,at+8)
            if offset+amount>len(data):raise ValueError('Signature range outside executable')
            signature=amount>0
        at+=length
    if at!=end or build is None:raise ValueError('Missing or inconsistent iOS build metadata')
    return {**build,'code_signature_blob_present':signature,'executable_sha256':hashlib.sha256(data).hexdigest()}

def inspect(path,manifest,expected_version,expected_build):
    path=Path(path);manifest=Path(manifest)
    with zipfile.ZipFile(path) as z:
        infos=z.infolist();names=[i.filename for i in infos]
        if len(set(names))!=len(names):raise ValueError('Duplicate ZIP entries')
        if sum(i.file_size for i in infos)>512*1024*1024:raise ValueError('Unexpectedly large application bundle')
        for name in names:
            p=PurePosixPath(name)
            if p.is_absolute() or '..' in p.parts or '\\' in name or not name.startswith('Payload/'):
                raise ValueError('Invalid IPA path')
            if name.lower().endswith(('.dczdata','.pp')):raise ValueError('External game payload was embedded')
        apps={PurePosixPath(n).parts[1] for n in names if len(PurePosixPath(n).parts)>1}
        if len(apps)!=1 or not next(iter(apps)).endswith('.app'):raise ValueError('Expected one Payload application')
        prefix='Payload/'+next(iter(apps))+'/'
        info=plistlib.loads(z.read(prefix+'Info.plist'))
        if info.get('CFBundleShortVersionString')!=expected_version or str(info.get('CFBundleVersion'))!=str(expected_build):
            raise ValueError('IPA version/build does not match release')
        if info.get('CFBundlePackageType')!='APPL' or info.get('CFBundleSupportedPlatforms')!=['iPhoneOS']:
            raise ValueError('Invalid device application metadata')
        executable=info.get('CFBundleExecutable','')
        if not executable or PurePosixPath(executable).name!=executable:raise ValueError('Invalid executable name')
        entry=z.getinfo(prefix+executable)
        if not (entry.external_attr>>16)&stat.S_IXUSR:raise ValueError('Executable permission is missing')
        binary=macho_device(z.read(entry))
        if version(info.get('MinimumOSVersion','0'))!=tuple(binary['minimum_os']):raise ValueError('Deployment targets disagree')
        embedded=z.read(prefix+'DczlrData.manifest.json')
        if embedded!=manifest.read_bytes():raise ValueError('Bundled resource manifest differs')
        if z.testzip() is not None:raise ValueError('IPA CRC verification failed')
    return {'product':path.name,'version':expected_version,'build':str(expected_build),
            'bundle_identifier':info.get('CFBundleIdentifier'),'executable':executable,**binary,
            'bytes':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
            'manifest_sha256':hashlib.sha256(embedded).hexdigest(),'zip_crc':'passed',
            'signing':'unsigned development package; own identity required','device_execution':'not tested'}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--ipa',type=Path,required=True);p.add_argument('--manifest',type=Path,required=True)
    p.add_argument('--version',required=True);p.add_argument('--build',required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    report=inspect(a.ipa,a.manifest,a.version,a.build);a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report))
if __name__=='__main__':main()
