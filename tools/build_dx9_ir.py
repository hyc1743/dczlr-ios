"""Build raw IR for an explicitly selected, framing-checked shader."""
from __future__ import annotations
import argparse, json
from pathlib import Path

OPCODES = {
    0: "nop", 1: "mov", 2: "add", 3: "sub", 4: "mad", 5: "mul", 6: "rcp", 7: "rsq",
    8: "dp3", 9: "dp4", 10: "min", 11: "max", 12: "slt", 13: "sge", 16: "lit",
    18: "lrp", 19: "frc", 31: "dcl", 32: "pow", 35: "abs", 36: "nrm", 37: "sincos",
    40: "if", 43: "endif", 44: "break", 47: "defb", 48: "defi", 64: "texcoord",
    65: "texkill", 66: "tex", 67: "texbem", 68: "texbeml", 69: "texreg2ar",
    70: "texreg2gb", 71: "texm3x2pad", 72: "texm3x2tex", 73: "texm3x3pad",
    74: "texm3x3tex", 75: "texm3x3diff", 76: "texm3x3spec", 77: "texm3x3vspec",
    78: "expp", 79: "logp", 80: "cnd", 81: "def", 82: "texreg2rgb",
    83: "texdp3tex", 84: "texm3x2depth", 85: "texdp3", 86: "texm3x3",
    87: "texdepth", 88: "cmp", 89: "bem", 90: "dp2add", 91: "dsx", 92: "dsy",
    93: "texldd", 94: "setp", 95: "texldl", 96: "breakp"
}

def main() -> None:
    p=argparse.ArgumentParser(description=__doc__); p.add_argument("parsed",type=Path); p.add_argument("--output",required=True,type=Path)
    p.add_argument("--effect", required=True); p.add_argument("--offset", required=True, type=lambda value: int(value, 0)); a=p.parse_args()
    source=json.loads(a.parsed.read_text(encoding='utf-8')); effects=[]
    if source.get('schema') != 2:
        raise ValueError('Old tolerant parse output is invalid; regenerate with the corrected framing parser')
    for effect in source['effects']:
        if effect['id'] != a.effect: continue
        selected=[x for x in effect.get('parsed_candidates',[]) if x.get('valid') and x.get('offset') == a.offset]
        if not selected: continue
        value=selected[0]
        instructions=[]
        for item in value.get('instructions',[]):
            opcode=item['opcode']; copy=dict(item); copy['mnemonic']=OPCODES.get(opcode,'opcode_'+str(opcode)); instructions.append(copy)
        effects.append({'id':effect['id'],'source_sha256':effect['source_sha256'],'profile':value['profile'],'shader_sha256':value['sha256'],'length':value['length'],'confidence':value.get('confidence'),'instructions':instructions})
    if len(effects) != 1:
        raise ValueError('No framing-checked shader matches the explicit effect and offset')
    result={'schema':2,'format':'dczlr-dx9-raw-ir-v2','artifact_sha256':source['artifact_sha256'],'method':'Explicit shader selection and token framing; register semantics and control flow are not reconstructed.','effects':effects,'limitations':['Operand tokens remain raw hexadecimal values.','Framing does not validate complete shader semantics.','This IR is not a Metal shader and cannot be executed.']}
    a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8'); print(f'Wrote raw IR for {len(effects)} effects')
if __name__=='__main__': main()
