#!/usr/bin/env python3
"""Stream Data into <=1 GB parts and restore/verify it from a manifest."""
from __future__ import annotations
import argparse, hashlib, json, os, shutil
from pathlib import Path

FORMAT = "dczlr-resource-parts-v1"
PART_BYTES = 1_000_000_000
CHUNK = 4 * 1024 * 1024

def files(data: Path):
    root = data.resolve()
    result=[]
    for p in sorted(root.rglob('*'), key=lambda value: value.relative_to(root).as_posix()):
        if p.is_file():
            rel=p.relative_to(root).as_posix()
            if any(x in ('','.','..') for x in rel.split('/')) or '\\' in rel: raise ValueError(f'unsafe path: {rel}')
            result.append((rel,p))
    return result

def digest(path: Path):
    h=hashlib.sha256(); size=0
    with path.open('rb') as f:
        while chunk:=f.read(CHUNK): h.update(chunk); size+=len(chunk)
    return size,h.hexdigest()

def pack(data: Path, out: Path, part_bytes: int):
    if type(part_bytes) is not int or not 0 < part_bytes <= PART_BYTES:
        raise ValueError('part_bytes must be between 1 and 1,000,000,000')
    if out.exists(): raise ValueError(f'output exists: {out}')
    out.mkdir(parents=True)
    records=[]; part_records=[]; part_index=0; offset=0; part_file=None; part_hash=None
    def open_part():
        nonlocal part_file,part_hash,offset
        name=f'DczlrData.part{len(part_records)+1:03d}.dczdata'; part_file=(out/(name+'.partial')).open('xb'); part_hash=hashlib.sha256(); offset=0; return name
    def close_part(name):
        nonlocal part_file
        temporary = Path(part_file.name)
        part_file.flush(); os.fsync(part_file.fileno()); part_file.close(); temporary.rename(out/name)
        part_records.append({'name':name,'size':offset,'sha256':part_hash.hexdigest()}); part_file=None
    for rel,path in files(data):
        size,sha=digest(path); seg=[]; remaining=size
        with path.open('rb') as src:
            while remaining:
                if part_file is None: name=open_part()
                n=min(remaining,part_bytes-offset,CHUNK); chunk=src.read(n)
                if len(chunk)!=n: raise ValueError(f'source changed: {rel}')
                part_file.write(chunk); part_hash.update(chunk); seg.append({'part':len(part_records),'offset':offset,'length':n}); offset+=n; remaining-=n
                if offset==part_bytes: close_part(name)
        records.append({'path':f'Data/{rel}','size':size,'sha256':sha,'segments':seg})
    if part_file is not None: close_part(name)
    manifest={'schema':1,'format':FORMAT,'game':'dczlr','part_bytes':part_bytes,'total_bytes':sum(x['size'] for x in records),'file_count':len(records),'parts':part_records,'files':records}
    manifest['source_identity_sha256']=hashlib.sha256(json.dumps([{'path':x['path'],'size':x['size'],'sha256':x['sha256']} for x in records],sort_keys=True,separators=(',',':')).encode()).hexdigest()
    (out/'DczlrData.manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    return manifest

def manifest_only(data: Path, output: Path, part_bytes: int):
    if type(part_bytes) is not int or not 0 < part_bytes <= PART_BYTES:
        raise ValueError('part_bytes must be between 1 and 1,000,000,000')
    records=[]; part_sizes=[]; part_index=0; offset=0
    for rel,path in files(data):
        size,sha=digest(path); segments=[]; remaining=size
        while remaining:
            if not part_sizes or offset==part_bytes:
                part_sizes.append(0); part_index=len(part_sizes)-1; offset=0
            n=min(remaining,part_bytes-offset); segments.append({'part':part_index,'offset':offset,'length':n}); offset+=n; part_sizes[part_index]+=n; remaining-=n
        records.append({'path':f'Data/{rel}','size':size,'sha256':sha,'segments':segments})
    part_hashes=[hashlib.sha256() for _ in part_sizes]
    # Hash each deterministic part by replaying the file stream in manifest order.
    current_part=0; current_offset=0
    for rel,path in files(data):
        with path.open('rb') as src:
            remaining=path.stat().st_size
            while remaining:
                n=min(remaining,part_bytes-current_offset,CHUNK); chunk=src.read(n)
                if len(chunk)!=n: raise ValueError(f'source changed: {rel}')
                part_hashes[current_part].update(chunk); current_offset+=n; remaining-=n
                if current_offset==part_bytes: current_part+=1; current_offset=0
    parts=[{'name':f'DczlrData.part{i+1:03d}.dczdata','size':size,'sha256':part_hashes[i].hexdigest()} for i,size in enumerate(part_sizes)]
    manifest={'schema':1,'format':FORMAT,'game':'dczlr','part_bytes':part_bytes,'total_bytes':sum(x['size'] for x in records),'file_count':len(records),'parts':parts,'files':records,'status':'source-stream-hashes-verified'}
    manifest['source_identity_sha256']=hashlib.sha256(json.dumps([{'path':x['path'],'size':x['size'],'sha256':x['sha256']} for x in records],sort_keys=True,separators=(',',':')).encode()).hexdigest()
    output.parent.mkdir(parents=True,exist_ok=True); output.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8'); return manifest

def load_manifest(parts: Path, manifest: Path|None):
    path=manifest or (parts/'DczlrData.manifest.json')
    doc=json.loads(path.read_text(encoding='utf-8'))
    if doc.get('schema')!=1 or doc.get('format')!=FORMAT or doc.get('game')!='dczlr': raise ValueError('unsupported manifest')
    if not 0<doc['part_bytes']<=PART_BYTES: raise ValueError('invalid part limit')
    if len(doc['parts'])==0 or len(doc['files'])!=doc['file_count']: raise ValueError('invalid inventory')
    cursor_part=0; cursor_offset=0; total=0; previous=None
    for item in doc['files']:
        path=item.get('path','')
        if not path.startswith('Data/') or '\\' in path or '/..' in path or path <= (previous or ''): raise ValueError('unsafe or unsorted file path')
        previous=path; covered=0
        for seg in item.get('segments',[]):
            if seg['part']!=cursor_part or seg['offset']!=cursor_offset or seg['length']<=0: raise ValueError('non-contiguous segments')
            if seg['part']>=len(doc['parts']) or seg['offset']+seg['length']>doc['parts'][seg['part']]['size']: raise ValueError('segment outside part')
            covered+=seg['length']; cursor_offset+=seg['length']; total+=seg['length']
            if cursor_offset==doc['parts'][seg['part']]['size']: cursor_part+=1; cursor_offset=0
        if covered!=item['size']: raise ValueError('file segment size mismatch')
    if total!=doc['total_bytes'] or cursor_part!=len(doc['parts']) or cursor_offset!=0: raise ValueError('stream coverage mismatch')
    return doc

def verify(parts: Path, manifest_path: Path|None, data: Path|None):
    m=load_manifest(parts,manifest_path); stream=[]
    for i,p in enumerate(m['parts']):
        if p['name']!=f'DczlrData.part{i+1:03d}.dczdata': raise ValueError('noncanonical part name')
        path=parts/p['name']; size,sha=digest(path)
        if size!=p['size'] or sha!=p['sha256']: raise ValueError(f'part mismatch: {p["name"]}')
        stream.append(path)
    if data:
        for item in m['files']:
            path=data/Path(item['path']).relative_to('Data'); size,sha=digest(path)
            if size!=item['size'] or sha!=item['sha256']: raise ValueError(f'file mismatch: {item["path"]}')
    return m

def restore(parts: Path, manifest_path: Path|None, out: Path):
    m=verify(parts,manifest_path,None)
    if out.exists(): raise ValueError(f'output exists: {out}')
    out.mkdir(parents=True)
    handles=[(parts/p['name']).open('rb') for p in m['parts']]
    try:
        for item in m['files']:
            target=out/Path(item['path']).relative_to('Data'); target.parent.mkdir(parents=True,exist_ok=True); tmp=target.with_suffix(target.suffix+'.partial'); h=hashlib.sha256(); total=0
            with tmp.open('xb') as dst:
                for seg in item['segments']:
                    f=handles[seg['part']]; f.seek(seg['offset']); remaining=seg['length']
                    while remaining:
                        chunk=f.read(min(CHUNK,remaining));
                        if not chunk: raise ValueError('truncated segment')
                        dst.write(chunk); h.update(chunk); total+=len(chunk); remaining-=len(chunk)
            if total!=item['size'] or h.hexdigest()!=item['sha256']: raise ValueError(f'restored hash mismatch: {item["path"]}')
            tmp.replace(target)
    finally:
        for f in handles: f.close()
    return m

def main():
    p=argparse.ArgumentParser(); sub=p.add_subparsers(dest='command',required=True)
    a=sub.add_parser('pack'); a.add_argument('--data',type=Path,required=True); a.add_argument('--out',type=Path,required=True); a.add_argument('--part-bytes',type=int,default=PART_BYTES)
    a=sub.add_parser('verify'); a.add_argument('--parts',type=Path,required=True); a.add_argument('--manifest',type=Path); a.add_argument('--data',type=Path)
    a=sub.add_parser('restore'); a.add_argument('--parts',type=Path,required=True); a.add_argument('--manifest',type=Path); a.add_argument('--out',type=Path,required=True)
    a=sub.add_parser('manifest'); a.add_argument('--data',type=Path,required=True); a.add_argument('--output',type=Path,required=True); a.add_argument('--part-bytes',type=int,default=PART_BYTES)
    x=p.parse_args()
    if x.command=='pack': pack(x.data,x.out,x.part_bytes); print('packed',x.out)
    elif x.command=='manifest': manifest_only(x.data,x.output,x.part_bytes); print('manifest',x.output)
    elif x.command=='verify': verify(x.parts,x.manifest,x.data); print('verified',x.parts)
    else: restore(x.parts,x.manifest,x.out); print('restored',x.out)
if __name__=='__main__': main()
