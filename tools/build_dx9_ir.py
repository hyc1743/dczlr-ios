"""Build a raw, lossless-ish intermediate representation for parsed DX9 shaders."""
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
    74: "texm3x3tex", 75: "texm3x3spec", 76: "texm3x3vspec", 81: "expp", 82: "logp",
    83: "cnd", 84: "def", 85: "texreg2rgb", 86: "texdp3tex", 87: "texm3x2depth",
    88: "texm3x2", 89: "texdepth", 0xAB00: "embedded_record"
}

def main() -> None:
    p=argparse.ArgumentParser(description=__doc__); p.add_argument("parsed",type=Path); p.add_argument("--output",required=True,type=Path); a=p.parse_args()
    source=json.loads(a.parsed.read_text(encoding='utf-8')); effects=[]
    for effect in source['effects']:
        preferred=[x for x in effect.get('parsed_candidates',[]) if x.get('preferred')]
        if not preferred: continue
        value=preferred[0]
        instructions=[]
        for item in value.get('instructions',[]):
            opcode=item['opcode']; copy=dict(item); copy['mnemonic']=OPCODES.get(opcode,'opcode_'+str(opcode)); instructions.append(copy)
        effects.append({'id':effect['id'],'source_sha256':effect['source_sha256'],'profile':value['profile'],'shader_sha256':value['sha256'],'length':value['length'],'confidence':value.get('confidence'),'instructions':instructions})
    result={'schema':1,'format':'dczlr-dx9-raw-ir-v1','artifact_sha256':source['artifact_sha256'],'method':'Raw token IR with bounded opcode labels; register semantics and control flow are not reconstructed.','effects':effects,'limitations':['Operand tokens remain raw hexadecimal values.','Unknown/embedded records retain numeric opcode labels.','This IR is not a Metal shader and cannot be executed.']}
    a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8'); print(f'Wrote raw IR for {len(effects)} effects')
if __name__=='__main__': main()
