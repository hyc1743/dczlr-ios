"""Bounded offline D3DX9 effect records; never creates a device or executes code.

The wire layout is documented against Wine effect.c / preshader.c at
840a939ee526137639665ff5f587224d6a36403f. This is an independent reader, not
Wine runtime code. Numeric, texture/shader object and sampler types are read;
structs and unknown types fail explicitly. FXLC programs remain opaque except
for a checked single scalar MOV from a named scalar/array parameter.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

from parse_dx9_shader import parse as parse_shader

MAGIC = 0xFEFF0901
MAX_COUNT = 16384
MAX_WORDS = 65536
REFERENCE = "wine-mirror/wine@840a939ee526137639665ff5f587224d6a36403f"


class EffectFormatError(ValueError):
    pass


class Reader:
    def __init__(self, data):
        self.data = data

    def region(self, offset, size):
        if offset < 0 or size < 0 or offset > len(self.data) or size > len(self.data) - offset:
            raise EffectFormatError(f"Range outside input: {offset}+{size}")
        return self.data[offset:offset + size]

    def words(self, offset, count=1):
        if count > MAX_WORDS:
            raise EffectFormatError("Word count exceeds analysis limit")
        return struct.unpack("<" + "I" * count, self.region(offset, count * 4))

    def u32(self, offset):
        return self.words(offset)[0]

    def count(self, offset):
        count = self.u32(offset)
        if count > MAX_COUNT:
            raise EffectFormatError("Record count exceeds analysis limit")
        return count

    def cstring(self, offset):
        self.region(offset, 1)
        end = self.data.find(b"\0", offset, min(len(self.data), offset + 4096))
        if end < 0:
            raise EffectFormatError("Unterminated or overlong name")
        try:
            return self.data[offset:end].decode("ascii")
        except UnicodeDecodeError as error:
            raise EffectFormatError("Non-ASCII metadata name") from error

    def name(self, offset):
        size = self.u32(offset)
        if size == 0:
            return None
        if size > 4096:
            raise EffectFormatError("Overlong name")
        data = self.region(offset + 4, size)
        if data[-1:] != b"\0" or b"\0" in data[:-1]:
            raise EffectFormatError("Invalid name terminator")
        try:
            return data[:-1].decode("ascii")
        except UnicodeDecodeError as error:
            raise EffectFormatError("Non-ASCII metadata name") from error


def scalar_copy_binding(blob):
    """Recognize only the measured FX 2.0 scalar-MOV profile; no evaluation.

    Any other *bounded* program returns None, retaining its opaque record.
    Malformed framing/offsets raise rather than silently accepting a binding.
    """
    if len(blob) < 4 or Reader(blob).u32(0) != 0x46580200:
        return None
    source = Reader(blob)
    sections = {}
    offset = 4
    terminated = False
    while offset < len(blob):
        token = source.u32(offset)
        if token == 0x0000ffff and offset + 4 == len(blob):
            offset += 4
            terminated = True
            break
        words = token >> 16
        if token & 0xffff != 0xfffe or not words:
            raise EffectFormatError("Invalid preshader comment")
        raw = source.region(offset + 4, words * 4)
        fourcc = raw[:4]
        if fourcc in sections:
            raise EffectFormatError("Duplicate preshader section")
        sections[fourcc] = raw[4:]
        offset += (words + 1) * 4
    if not terminated:
        raise EffectFormatError("Missing preshader terminator")
    if set(sections) != {b"CTAB", b"CLIT", b"FXLC"}:
        return None
    code = Reader(sections[b"FXLC"])
    # count, MOV-one-component, one source, no indirection, constant-table
    # component offset, no indirection, float output, component zero.
    if len(code.data) != 44:
        return None
    ins = code.words(0, 11)
    if ins[:5] != (1, 0x10000001, 1, 0, 2) or ins[6] != 0 or ins[7] not in (4, 5, 6) or ins[8] != 0:
        return None
    if ins[9:] != (0xf0f0f0f0, 0x0f0f0f0f) or sections[b"CLIT"] != b"\0" * 4:
        return None
    ctab = Reader(sections[b"CTAB"])
    size, creator, version, count, info_offset, flags, target = ctab.words(0, 7)
    if size != 28 or version != 0x46580200 or count != 1:
        return None
    ctab.cstring(creator)
    if target:
        ctab.cstring(target)
    raw = ctab.region(info_offset, 20)
    name_offset, register_set, register_index, register_count, reserved, type_offset, default = struct.unpack("<IHHHHII", raw)
    shape = struct.unpack("<6HI", ctab.region(type_offset, 16))
    class_, type_, rows, columns, elements, members, member_info = shape
    if register_set != 2 or reserved or class_ != 0 or type_ not in (1, 2, 3) or (rows, columns) != (1, 1) or members or member_info:
        return None
    component = ins[5]
    if component % 4 or not register_index * 4 <= component < (register_index + register_count) * 4:
        raise EffectFormatError("Scalar MOV reads outside its declared constants")
    element = component // 4 - register_index
    if element >= max(elements, 1):
        raise EffectFormatError("Scalar MOV reads outside its declared array")
    if default:
        ctab.region(default, register_count * 16)
    return {"kind": "scalar_parameter_copy", "parameter": ctab.cstring(name_offset),
            "element": element, "parameter_type": type_, "declared_elements": elements,
            "output_table": ins[7]}


class EffectReader(Reader):
    def __init__(self, data):
        if len(data) < 8 or len(data) > 16 * 1024 * 1024:
            raise EffectFormatError("Invalid effect length")
        envelope = Reader(data)
        if envelope.u32(0) != MAGIC:
            raise EffectFormatError("Unknown effect tag")
        self.start = envelope.u32(4)
        super().__init__(data[8:])
        self.object_count = 0
        self.nodes = 0
        self.source_sha256 = hashlib.sha256(data).hexdigest()

    def typedef(self, offset):
        self.nodes += 1
        if self.nodes > MAX_COUNT:
            raise EffectFormatError("Too many type records")
        type_, class_, name, semantic, elements = self.words(offset, 5)
        if elements > 4096:
            raise EffectFormatError("Type array exceeds analysis limit")
        result = {"type": type_, "class": class_, "name": self.name(name),
                  "semantic": self.name(semantic), "elements": elements,
                  "type_offset": offset + 8}
        if class_ in (0, 1, 2, 3):
            if type_ not in (1, 2, 3):
                raise EffectFormatError("Unknown numeric type")
            a, b = self.words(offset + 20, 2)
            rows, columns = (b, a) if class_ == 1 else (a, b)
            if not 1 <= rows <= 4 or not 1 <= columns <= 4:
                raise EffectFormatError("Invalid numeric shape")
            result.update(rows=rows, columns=columns)
        elif class_ != 4 or type_ not in range(4, 17):
            raise EffectFormatError(f"Unsupported type/class {type_}/{class_}")
        return result

    def value(self, type_, offset, depth=0):
        if depth > 16:
            raise EffectFormatError("Sampler nesting exceeds analysis limit")
        result = {"value_offset": offset + 8}
        count = max(1, type_["elements"])
        if type_["class"] != 4:
            words = count * type_["rows"] * type_["columns"]
            result["words"] = list(self.words(offset, words))
            return result
        if 10 <= type_["type"] <= 14:
            samplers = []
            for _ in range(count):
                states = self.count(offset)
                offset += 4
                items = []
                self.region(offset, states * 16)
                for _ in range(states):
                    item = self.state(offset, depth + 1)
                    offset += 16
                    items.append(item)
                samplers.append(items)
            result["samplers"] = samplers
        else:
            ids = list(self.words(offset, count))
            if any(value >= self.object_count for value in ids):
                raise EffectFormatError("Object ID outside object table")
            result["object_ids"] = ids
        return result

    def annotation(self, offset):
        typ, value = self.words(offset, 2)
        shape = self.typedef(typ)
        return {"type": shape, "value": self.value(shape, value)}

    def annotations(self, offset, count):
        if count > MAX_COUNT:
            raise EffectFormatError("Too many annotations")
        self.region(offset, count * 8)
        return [self.annotation(offset + i * 8) for i in range(count)]

    def state(self, offset, depth=0):
        op, index, typ, value = self.words(offset, 4)
        if op > 0xb2:
            raise EffectFormatError(f"Unknown state operation {op}")
        shape = self.typedef(typ)
        return {"record_offset": offset + 8, "operation": op, "index": index,
                "type": shape, "initial": self.value(shape, value, depth)}

    def parse(self):
        parameters, techniques, shader_slots, self.object_count = self.words(self.start, 4)
        if any(n > MAX_COUNT for n in (parameters, techniques, shader_slots, self.object_count)):
            raise EffectFormatError("Effect count exceeds analysis limit")
        offset = self.start + 16
        params = []
        for _ in range(parameters):
            typ, value, flags, count = self.words(offset, 4)
            shape = self.typedef(typ)
            annotations = self.annotations(offset + 16, count)
            offset += 16 + count * 8
            params.append({"type": shape, "value": self.value(shape, value),
                           "flags": flags, "annotations": annotations})
        techs = []
        for _ in range(techniques):
            name, count, passes = self.words(offset, 3)
            annotations = self.annotations(offset + 12, count)
            offset += 12 + count * 8
            if passes > MAX_COUNT:
                raise EffectFormatError("Too many passes")
            items = []
            for _ in range(passes):
                pname, count, states = self.words(offset, 3)
                panno = self.annotations(offset + 12, count)
                offset += 12 + count * 8
                if states > MAX_COUNT:
                    raise EffectFormatError("Too many states")
                self.region(offset, states * 16)
                items.append({"name": self.name(pname), "annotations": panno,
                              "states": [self.state(offset + i * 16) for i in range(states)]})
                offset += states * 16
            techs.append({"name": self.name(name), "annotations": annotations, "passes": items})
        strings, resources = self.words(offset, 2)
        offset += 8
        if strings > MAX_COUNT or resources > MAX_COUNT:
            raise EffectFormatError("Too many object/resource records")
        objects = []
        for _ in range(strings):
            oid, size = self.words(offset, 2)
            offset += 8
            if oid >= self.object_count:
                raise EffectFormatError("String/object ID outside object table")
            raw = self.region(offset, size)
            objects.append({"id": oid, **self.blob(raw, offset)})
            self.region(offset, (size + 3) & ~3)
            offset += (size + 3) & ~3
        for _ in range(resources):
            technique, parent, element, state_index, usage, size = self.words(offset, 6)
            offset += 24
            if technique == 0xffffffff:
                if parent >= len(params):
                    raise EffectFormatError("Resource parent outside parameter table")
                samplers = params[parent]["value"].get("samplers", [])
                if element == 0xffffffff:
                    element = 0
                if element >= len(samplers) or state_index >= len(samplers[element]):
                    raise EffectFormatError("Resource targets invalid sampler state")
                state = samplers[element][state_index]
            else:
                if technique >= len(techs) or parent >= len(techs[technique]["passes"]):
                    raise EffectFormatError("Resource targets invalid technique/pass")
                states = techs[technique]["passes"][parent]["states"]
                if state_index >= len(states):
                    raise EffectFormatError("Resource targets invalid pass state")
                state = states[state_index]
            if usage not in (0, 1, 2) or "binding" in state:
                raise EffectFormatError("Unknown or duplicate resource binding")
            raw = self.region(offset, size)
            binding = {"usage": usage, **self.blob(raw, offset)}
            if usage == 1:
                name_reader = Reader(raw)
                binding["parameter"] = name_reader.cstring(0)
                if raw != binding["parameter"].encode() + b"\0":
                    raise EffectFormatError("Parameter reference has trailing data")
            elif usage == 0 and raw[:4] == b"\0\x02XF":
                copy = scalar_copy_binding(raw)
                if copy:
                    binding.update(copy)
            elif usage == 2:
                selector = Reader(raw)
                size_name = selector.u32(0)
                if not size_name or size_name > 4096 or size_name % 4:
                    raise EffectFormatError("Invalid array selector name size")
                raw_name = selector.region(4, size_name)
                name = selector.cstring(4)
                if raw_name[len(name):] != b"\0" * (size_name - len(name)):
                    raise EffectFormatError("Invalid array selector name padding")
                program = raw[4 + size_name:]
                binding.update(kind="parameter_array_selector", parameter=name,
                               selector=self.blob(program, offset + 4 + size_name))
                copy = scalar_copy_binding(program)
                if copy:
                    binding["selector"].update(copy)
            state["binding"] = binding
            self.region(offset, (size + 3) & ~3)
            offset += (size + 3) & ~3
        if offset != len(self.data):
            raise EffectFormatError("Unparsed effect tail")
        names = {p["type"]["name"]: p for p in params}
        if None in names or len(names) != len(params):
            raise EffectFormatError("Missing or duplicate parameter names")
        bindings = []
        for t in techs:
            for p in t["passes"]:
                bindings.extend(s["binding"] for s in p["states"] if "binding" in s)
        for p in params:
            for sampler in p["value"].get("samplers", []):
                bindings.extend(s["binding"] for s in sampler if "binding" in s)
        for binding in bindings + [b["selector"] for b in bindings if b.get("kind") == "parameter_array_selector"]:
            if "parameter" not in binding:
                continue
            param = names.get(binding["parameter"])
            if param is None:
                raise EffectFormatError("Binding references missing parameter")
            if binding.get("kind") == "scalar_parameter_copy":
                shape = param["type"]
                if (shape["class"], shape["type"], shape.get("rows"), shape.get("columns"), max(1, shape["elements"])) != (
                        0, binding["parameter_type"], 1, 1, max(1, binding["declared_elements"])):
                    raise EffectFormatError(f"Binding and parameter type disagree: {shape} / {binding}")
            if binding.get("kind") == "parameter_array_selector" and not param["type"]["elements"]:
                raise EffectFormatError("Selector references non-array parameter")
        return {"schema": 1, "source_sha256": self.source_sha256,
                "offset_base": "effect payload + 8 bytes; reported offsets are payload-relative",
                "parameter_count": parameters, "technique_count": techniques,
                "shader_slot_count": shader_slots, "object_count": self.object_count,
                "parameters": params, "techniques": techs, "objects": objects,
                "resource_binding_count": resources,
                "scalar_copy_bindings": sum(b.get("kind") == "scalar_parameter_copy" for b in bindings),
                "limits": ["State metadata is not a Vulkan pipeline or a shader conversion.",
                           "Unknown FXLC arithmetic remains opaque; no bytecode is executed.",
                           "Runtime parameter changes and selected passes are not observed."]}

    @staticmethod
    def blob(raw, offset):
        result = {"offset": offset + 8, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
        if len(raw) >= 4 and struct.unpack_from("<I", raw)[0] in (0xfffe0200, 0xffff0200, 0xfffe0300, 0xffff0300):
            framed = parse_shader(raw, 0)
            result["shader_framing"] = {k: v for k, v in framed.items()
                                        if k in ("valid", "reason", "profile", "length", "sha256")}
        return result


def parse(data):
    return EffectReader(data).parse()


def shader_records(effect, data):
    """Recover declared shader ranges and their static pass alternatives.

    Array selectors retain every declared alternative, without guessing which
    one a runtime value selects. The ranges come from object/resource records,
    never from scanning for version tokens inside comments.
    """
    if hashlib.sha256(data).hexdigest() != effect["source_sha256"]:
        raise EffectFormatError("Shader inventory input differs from parsed effect")
    objects = {}
    for obj in effect["objects"]:
        if obj["id"] in objects:
            raise EffectFormatError("Ambiguous duplicate object record")
        objects[obj["id"]] = obj
    params = {p["type"]["name"]: p for p in effect["parameters"]}
    records = {}

    def add(blob, owner, stage):
        if not blob["bytes"]:
            return
        offset, size = blob["offset"], blob["bytes"]
        raw = Reader(data).region(offset, size)
        if hashlib.sha256(raw).hexdigest() != blob["sha256"] or len(raw) < 8:
            raise EffectFormatError("Shader bytes differ from record")
        token = struct.unpack_from("<I", raw)[0]
        expected = 0xfffe if stage == "vertex" else 0xffff
        if token >> 16 != expected or (token >> 8) & 255 not in (1, 2, 3):
            raise EffectFormatError("Shader version/stage disagrees with owning declaration")
        key = offset, size
        if key not in records:
            records[key] = {**blob, "stage": stage,
                            "profile": ("vs" if stage == "vertex" else "ps") +
                            f"_{(token >> 8) & 255}_{token & 255}", "owners": []}
        if owner not in records[key]["owners"]:
            records[key]["owners"].append(owner)

    def parameter(name, owner, expected_stage=None):
        param = params[name]
        if param["type"]["type"] not in (15, 16):
            raise EffectFormatError("Shader binding references non-shader parameter")
        stage = "vertex" if param["type"]["type"] == 16 else "pixel"
        if expected_stage is not None and stage != expected_stage:
            raise EffectFormatError("Pass stage and referenced shader parameter disagree")
        for element, oid in enumerate(param["value"]["object_ids"]):
            if oid not in objects:
                raise EffectFormatError("Shader object has no data record")
            add(objects[oid], f"{owner}:{name}[{element}]", stage)

    for name, param in params.items():
        if param["type"]["type"] in (15, 16):
            parameter(name, "parameter")
    for tech in effect["techniques"]:
        for pass_ in tech["passes"]:
            for state in pass_["states"]:
                if state["operation"] not in (0x92, 0x93):
                    continue
                stage = "vertex" if state["operation"] == 0x92 else "pixel"
                owner = tech["name"] + "/" + pass_["name"] + "/" + stage
                binding = state.get("binding")
                if binding:
                    if binding["usage"] == 0:
                        add(binding, owner, stage)
                    else:
                        parameter(binding["parameter"], owner, stage)
                elif state["initial"].get("words") != [0]:
                    raise EffectFormatError("Unresolved non-null shader state")
    return list(records.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("exe", type=Path)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--id")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = args.exe.read_bytes()
    evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
    if hashlib.sha256(source).hexdigest() != evidence["artifact"]["sha256"]:
        raise EffectFormatError("Input differs from recorded artifact")
    effects = []
    for record in evidence["named_resources"]:
        if args.id and record["name"] != args.id:
            continue
        data = source[record["file_offset"]:record["file_offset"] + record["bytes"]]
        if len(data) != record["bytes"] or hashlib.sha256(data).hexdigest() != record["sha256"]:
            raise EffectFormatError("Resource differs from recorded range/hash")
        effect = parse(data)
        effect["shader_records"] = shader_records(effect, data)
        effects.append({"id": record["name"], **effect})
    if not effects:
        raise EffectFormatError("No selected effects")
    result = {"schema": 1, "artifact_sha256": evidence["artifact"]["sha256"],
              "layout_reference": REFERENCE, "effects": effects}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(json.dumps([{k: e[k] for k in ["id", "parameter_count", "technique_count", "resource_binding_count", "scalar_copy_bindings"]} for e in effects]))


if __name__ == "__main__":
    main()
