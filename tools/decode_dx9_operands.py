"""Decode conservative DX9 operand-token fields for the raw IR."""
from __future__ import annotations
import argparse, json
from pathlib import Path

def decode(value: int) -> dict:
    return {
        "raw": f"0x{value:08x}",
        "register_number_candidate": value & 0x7FF,
        "relative_addressing_bit_candidate": bool(value & 0x2000),
        "modifier_bits_candidate": (value >> 16) & 0xFF,
        "register_type_low_candidate": (value >> 28) & 0x7,
        "register_type_high_candidate": (value >> 8) & 0x18,
    }

def main() -> None:
    p=argparse.ArgumentParser(description=__doc__); p.add_argument("ir",type=Path); p.add_argument("--output",required=True,type=Path); a=p.parse_args()
    source=json.loads(a.ir.read_text(encoding='utf-8')); effects=[]
    for effect in source['effects']:
        instructions=[]
        for instruction in effect['instructions']:
            item=dict(instruction); item['decoded_operands']=[decode(int(x,16)) for x in instruction['operands']]; instructions.append(item)
        effects.append({**{k:effect[k] for k in ('id','source_sha256','profile','shader_sha256','length','confidence')},'instructions':instructions})
    result={'schema':1,'format':'dczlr-dx9-operand-ir-v1','artifact_sha256':source['artifact_sha256'],'method':'Conservative bit-field decoding; register type and modifier semantics remain candidates.','effects':effects,'limitations':['DX9 register-type bit layout is not asserted by these candidate fields.','Relative addressing and swizzles need full instruction grammar validation.','This output is not executable shader code.']}
    a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8'); print(f'Wrote operand IR for {len(effects)} effects')
if __name__=='__main__': main()
