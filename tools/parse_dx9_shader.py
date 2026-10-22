"""Validate SM2/SM3 token framing; this is not a semantic shader validator."""
from __future__ import annotations
import argparse, hashlib, json, struct
from pathlib import Path

PROFILES = {0xFFFE0200: "vs_2_0", 0xFFFF0200: "ps_2_0", 0xFFFE0300: "vs_3_0", 0xFFFF0300: "ps_3_0"}
END = 0x0000FFFF
COMMENT = 0x0000FFFE
OPCODES = set(range(49)) | set(range(64, 97))
ZERO_OPERAND_OPCODES = {0, 28, 29, 39, 42, 43, 44}
# Wine 840a939ee526137639665ff5f587224d6a36403f:
# dlls/d3dx9_36/shader.c get_instr_length returns following words;
# its caller advances get_instr_length(...) + 1. Comments have the same rule.

def parse(data: bytes, start: int, limit: int = 256 * 1024) -> dict:
    if start < 0 or start % 4 or start + 4 > len(data) or limit < 8: return {"valid": False, "reason": "unaligned_or_truncated"}
    profile_token = struct.unpack_from("<I", data, start)[0]
    profile = PROFILES.get(profile_token)
    if profile is None: return {"valid": False, "reason": "missing_profile"}
    pos = start + 4; end_limit = min(len(data), start + limit); opcodes=[]; instructions=[]; comments=0; comment_ranges=[]
    while pos + 4 <= end_limit:
        token = struct.unpack_from("<I", data, pos)[0]; opcode = token & 0xFFFF
        if token == END:
            length = pos + 4 - start
            return {"valid": True, "confidence": "token-framing-only", "profile": profile, "offset": start, "length": length,
                    "sha256": hashlib.sha256(data[start:pos + 4]).hexdigest(),
                    "instruction_count": len(opcodes), "comment_count": comments,
                    "uncertain_token_count": 0, "padding_token_count": 0,
                    "opcodes": opcodes, "instructions": instructions, "comment_ranges": comment_ranges}
        if opcode == COMMENT:
            words = (token >> 16) & 0x7FFF
            if pos + (words + 1) * 4 > end_limit: return {"valid": False, "reason": "invalid_comment_length"}
            comment_ranges.append({"offset": pos - start, "length": (words + 1) * 4})
            comments += 1; pos += (words + 1) * 4; continue
        words = (token >> 24) & 0x0F
        if token & 0x80000000 or opcode not in OPCODES:
            return {"valid": False, "reason": "unknown_instruction_token", "at": pos - start, "token": f"0x{token:08x}"}
        if (words == 0 and opcode not in ZERO_OPERAND_OPCODES) or pos + (words + 1) * 4 > end_limit:
            return {"valid": False, "reason": "invalid_instruction_length", "at": pos - start, "token": f"0x{token:08x}"}
        operands = [struct.unpack_from("<I", data, pos + 4 + i * 4)[0] for i in range(words)]
        opcodes.append(opcode)
        instructions.append({"offset": pos - start, "token": f"0x{token:08x}", "words": words + 1,
                             "opcode": opcode, "operands": [f"0x{x:08x}" for x in operands]})
        pos += (words + 1) * 4
    return {"valid": False, "reason": "missing_end"}

def main() -> None:
    p=argparse.ArgumentParser(description=__doc__); p.add_argument("exe",type=Path); p.add_argument("candidates",type=Path); p.add_argument("evidence",type=Path); p.add_argument("--output",required=True,type=Path); a=p.parse_args()
    source=json.loads(a.evidence.read_text(encoding='utf-8')); cand=json.loads(a.candidates.read_text(encoding='utf-8')); blob=a.exe.read_bytes(); by_id={x['name']:x for x in source['named_resources']}; effects=[]
    if hashlib.sha256(blob).hexdigest() != source['artifact']['sha256'] or cand['artifact_sha256'] != source['artifact']['sha256']:
        raise ValueError('Artifact SHA-256 differs from source evidence')
    for item in cand['effects']:
        res=by_id[item['id']]; data=blob[res['file_offset']:res['file_offset']+res['bytes']]
        if len(data) != res['bytes'] or hashlib.sha256(data).hexdigest() != res['sha256']:
            raise ValueError('Resource bytes differ from source evidence: ' + item['id'])
        parsed=[parse(data,x['offset']) for x in item['candidates']]
        comment_intervals = []
        for value in parsed:
            if not value.get('valid'):
                continue
            start = value['offset']
            if any(begin <= start < end for begin, end in comment_intervals):
                value['valid'] = False
                value['reason'] = 'profile_token_inside_comment'
                continue
            for region in value['comment_ranges']:
                begin = start + region['offset']
                comment_intervals.append((begin, begin + region['length']))
        for value in parsed:
            value['preferred'] = False
        effects.append({'id':item['id'],'source_sha256':item['source_sha256'],'parsed_candidates':parsed})
    result={'schema':2,'artifact_sha256':source['artifact']['sha256'],'method':'SM2/SM3 token framing with instruction/comment token excluded from encoded payload lengths.','effects':effects,'limitations':['Framing checks do not validate instruction arity, register semantics or control flow.','No preferred shader is inferred from comment counts or shader length.','Technique/pass ownership and runtime use remain unknown.']}
    a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8'); print('Parsed candidate structure')
if __name__=='__main__': main()
