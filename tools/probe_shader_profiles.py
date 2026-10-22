"""Locate aligned DX9 shader profile tokens inside verified effect payloads."""
from __future__ import annotations
import argparse,json,struct
from pathlib import Path

PROFILES={0xfffe0200:'vs_2_0',0xffff0200:'ps_2_0',0xfffe0300:'vs_3_0',0xffff0300:'ps_3_0'}

def run(exe:Path,evidence:Path)->dict:
    source=json.loads(evidence.read_text(encoding='utf-8')); blob=exe.read_bytes(); effects=[]
    for item in source['named_resources']:
        data=blob[item['file_offset']:item['file_offset']+item['bytes']]; hits=[]
        for offset in range(0,len(data)-3,4):
            token=struct.unpack_from('<I',data,offset)[0]
            if token in PROFILES: hits.append({'offset':offset,'profile':PROFILES[token],'token':f'0x{token:08x}'})
        # Repeated tokens occur in effect metadata tables; retain counts and first offsets.
        counts={profile:sum(h['profile']==profile for h in hits) for profile in sorted(set(h['profile'] for h in hits))}
        effects.append({'id':item['name'],'source_sha256':item['sha256'],'aligned_token_count':len(hits),'profile_counts':counts,'first_offsets':hits[:32]})
    return {'schema':1,'artifact_sha256':source['artifact']['sha256'],'method':'Aligned little-endian token scan; no shader disassembly or execution.','effects':effects,'limitations':['Tokens may occur in duplicated metadata tables.','Token presence does not establish technique selection or complete shader boundaries.','IDR_SPRITE has no aligned profile token in this bounded scan; it needs a separate parser path.']}

def main():
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('exe',type=Path); p.add_argument('evidence',type=Path); p.add_argument('--output',required=True,type=Path); a=p.parse_args(); r=run(a.exe,a.evidence); a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(r,ensure_ascii=False,indent=2)+'\n',encoding='utf-8'); print(f"Probed shader profiles for {len(r['effects'])} effects")
if __name__=='__main__': main()
