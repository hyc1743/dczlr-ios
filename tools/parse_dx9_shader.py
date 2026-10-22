"""Conservatively validate DX9 shader bytecode candidates."""
from __future__ import annotations
import argparse, hashlib, json, struct
from pathlib import Path

PROFILES = {0xFFFE0200: "vs_2_0", 0xFFFF0200: "ps_2_0", 0xFFFE0300: "vs_3_0", 0xFFFF0300: "ps_3_0"}
END = 0x0000FFFF
COMMENT = 0x0000FFFE

def parse(data: bytes, start: int, limit: int = 256 * 1024) -> dict:
    if start % 4 or start + 4 > len(data): return {"valid": False, "reason": "unaligned_or_truncated"}
    profile_token = struct.unpack_from("<I", data, start)[0]
    profile = PROFILES.get(profile_token)
    if profile is None: return {"valid": False, "reason": "missing_profile"}
    pos = start + 4; end_limit = min(len(data), start + limit); opcodes=[]; instructions=[]; comments=0; uncertain=0; padding=0
    while pos + 4 <= end_limit:
        token = struct.unpack_from("<I", data, pos)[0]; opcode = token & 0xFFFF
        if token == END:
            length = pos + 4 - start
            return {"valid": True, "confidence": "bounded-tolerant", "profile": profile, "offset": start, "length": length,
                    "sha256": hashlib.sha256(data[start:pos + 4]).hexdigest(),
                    "instruction_count": len(opcodes), "comment_count": comments,
                    "uncertain_token_count": uncertain, "padding_token_count": padding,
                    "opcodes": opcodes[:256], "instructions": instructions[:256]}
        if opcode == COMMENT:
            words = (token >> 16) & 0x7FFF
            if words <= 0 or pos + words * 4 > end_limit: return {"valid": False, "reason": "invalid_comment_length"}
            comments += 1; pos += words * 4; continue
        words = (token >> 24) & 0x0F
        if words <= 0:
            # Some embedded effect records contain padding or instruction-like
            # tokens whose length field is not usable without full DX9 grammar.
            # Advance one token and retain this uncertainty in the result.
            if token == 0xABABAB00:
                padding += 1
            else:
                uncertain += 1; opcodes.append(opcode)
                instructions.append({"offset": pos - start, "token": f"0x{token:08x}", "words": 1,
                                     "opcode": opcode, "operands": []})
            pos += 4; continue
        if words > 64 or pos + words * 4 > end_limit:
            return {"valid": False, "reason": "invalid_instruction_length", "at": pos - start, "token": f"0x{token:08x}"}
        operands = [struct.unpack_from("<I", data, pos + 4 + i * 4)[0] for i in range(words - 1)]
        opcodes.append(opcode)
        instructions.append({"offset": pos - start, "token": f"0x{token:08x}", "words": words,
                             "opcode": opcode, "operands": [f"0x{x:08x}" for x in operands]})
        pos += words * 4
    return {"valid": False, "reason": "missing_end"}

def main() -> None:
    p=argparse.ArgumentParser(description=__doc__); p.add_argument("exe",type=Path); p.add_argument("candidates",type=Path); p.add_argument("evidence",type=Path); p.add_argument("--output",required=True,type=Path); a=p.parse_args()
    source=json.loads(a.evidence.read_text(encoding='utf-8')); cand=json.loads(a.candidates.read_text(encoding='utf-8')); blob=a.exe.read_bytes(); by_id={x['name']:x for x in source['named_resources']}; effects=[]
    for item in cand['effects']:
        res=by_id[item['id']]; data=blob[res['file_offset']:res['file_offset']+res['bytes']]
        parsed=[parse(data,x['offset']) for x in item['candidates']]
        valid=[x for x in parsed if x.get('valid')]
        if valid:
            preferred=max(valid, key=lambda x: (x.get('comment_count', 0), -x.get('instruction_count', 0), x['length']))
            for value in parsed:
                value['preferred'] = value is preferred
        effects.append({'id':item['id'],'source_sha256':item['source_sha256'],'parsed_candidates':parsed})
    result={'schema':1,'artifact_sha256':source['artifact']['sha256'],'method':'Bounded DX9 token-length/comment/end validation; no disassembly or execution.','effects':effects,'limitations':['Some embedded tokens lack a usable length field and are retained as uncertainty.','Opcode numbers are retained without semantic decoding.','A structurally valid blob still needs technique/pass association and shader translation.']}
    a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8'); print('Parsed candidate structure')
if __name__=='__main__': main()
