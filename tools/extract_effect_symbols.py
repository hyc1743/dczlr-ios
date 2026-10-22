"""Extract bounded D3DX effect symbol names from verified PE resources."""
from __future__ import annotations
import argparse, json, re
from pathlib import Path

def extract(exe: Path, evidence: Path) -> dict:
    source=json.loads(evidence.read_text(encoding='utf-8')); blob=exe.read_bytes(); out=[]
    for item in source['named_resources']:
        data=blob[item['file_offset']:item['file_offset']+item['bytes']]
        strings=[m.group().decode('ascii') for m in re.finditer(rb'[A-Za-z_][A-Za-z0-9_]{2,63}',data)]
        def unique(values): return list(dict.fromkeys(values))
        params=unique([s for s in strings if s.startswith('g_')])
        techniques=unique([s for s in strings if s.startswith('giTech')])
        passes=unique([s for s in strings if s == 'Pass0'])
        textures=unique([s for s in params if s.startswith('g_tx')])
        out.append({'id':item['name'],'source_sha256':item['sha256'],'parameter_names':params[:256],
                    'technique_names':techniques[:128],'pass_names':passes[:32],
                    'texture_parameters':textures[:128],
                    'compiler_strings':unique([s for s in strings if 'D3DX9 Shader Compiler' in s])[:8]})
    return {'schema':1,'artifact_sha256':source['artifact']['sha256'],
            'method':'Bounded printable symbol extraction from REA-verified resource ranges; no bytecode execution.',
            'effects':out,'limitations':['Names are observations, not a complete effect parse.','Pass0 repetition is deduplicated and does not establish pass count.','Technique names do not establish selected runtime technique.']}

def main():
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('exe',type=Path); p.add_argument('evidence',type=Path); p.add_argument('--output',required=True,type=Path); a=p.parse_args()
    result=extract(a.exe,a.evidence); a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8'); print(f"Extracted symbols for {len(result['effects'])} effects")
if __name__=='__main__': main()
