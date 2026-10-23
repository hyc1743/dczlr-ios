"""Apply the scoped LGPL TEXM3X2 extension to hash-pinned vkd3d 2.1 IR.

The original upstream source archive, this script and the added C source are
included with built tools so the exact modified library can be rebuilt.
"""
import argparse
import hashlib
import json
from pathlib import Path

ORIGINAL_IR_SHA256 = "a7dbd41ca82bdb8d64e5cb7abcb3742811e0e034748794f75fc5abbe35ce162a"


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("Pinned upstream patch context differs")
    return text.replace(old, new, 1)


def apply(source):
    path = source / "libs/vkd3d-shader/ir.c"
    original = path.read_bytes()
    if hashlib.sha256(original).hexdigest() != ORIGINAL_IR_SHA256:
        raise ValueError("Patch requires unmodified pinned vkd3d 2.1 ir.c")
    addition = Path(__file__).parent / "patches/vkd3d-2.1-texm3x2.c"
    start = "static enum vkd3d_result vsir_program_lower_d3dbc_instructions("
    text = original.decode("utf-8")
    begin = text.index(start)
    end = text.index("\nstatic ", begin + len(start))
    function = text[begin:end]
    function = replace_once(function, "    unsigned int tmp_idx = ~0u;\n",
                            "    unsigned int tmp_idx = ~0u;\n    unsigned int matrix_temp = ~0u, matrix_stage = ~0u;\n")
    function = replace_once(function, "            case VSIR_OP_TEXM3x2PAD:\n            case VSIR_OP_TEXM3x2TEX:\n", "")
    function = replace_once(function, "            case VSIR_OP_TEXDP3:\n",
        "            case VSIR_OP_TEXM3x2PAD:\n            case VSIR_OP_TEXM3x2TEX:\n"
        "                ret = portlab_lower_texm3x2(program, &it, &matrix_temp, &matrix_stage, message_context);\n"
        "                break;\n\n            case VSIR_OP_TEXDP3:\n")
    function = replace_once(function, "    return VKD3D_OK;\n}",
        "    if (matrix_temp != ~0u)\n    {\n"
        "        vkd3d_shader_error(message_context, NULL, VKD3D_SHADER_ERROR_VSIR_NOT_IMPLEMENTED,\n"
        '                "Unmatched TEXM3X2PAD instruction.");\n'
        "        return VKD3D_ERROR_NOT_IMPLEMENTED;\n    }\n    return VKD3D_OK;\n}")
    patched = (text[:begin] + addition.read_text(encoding="utf-8") + "\n" + function + text[end:]).encode()
    path.write_bytes(patched)
    report = {"schema": 1, "upstream_version": "2.1", "license": "LGPL-2.1-or-later",
              "original_ir_sha256": ORIGINAL_IR_SHA256, "patched_ir_sha256": hashlib.sha256(patched).hexdigest(),
              "extension_sha256": hashlib.sha256(addition.read_bytes()).hexdigest(),
              "scope": "ps_1_x consecutive TEXM3X2PAD/TEX, 2D nonprojected noncomparison sampler"}
    (source / "portlab-patch-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    print(json.dumps(apply(parser.parse_args().source)))
