"""Synthetic XX model fixtures with no original names, geometry or textures."""
import struct


def u32(value): return struct.pack("<I", value)


def name(value):
    return u32(len(value)) + bytes(b ^ 255 for b in value)


def matrix():
    return struct.pack("<16f", *(1.0 if i % 5 == 0 else 0.0 for i in range(16)))


def node(children=(), uv_sets=None):
    data = name(b"synthetic-node\0") + u32(len(children)) + matrix() + bytes(16)
    data += u32(int(uv_sets is not None)) + bytes(40)
    if uv_sets is not None:
        data += bytes((uv_sets,)) + bytes(16) + u32(0) + u32(3) + struct.pack("<3H", 0, 1, 2)
        data += u32(3) + bytes(3 * 52) + bytes(3 * 8 * uv_sets)
        data += struct.pack("<H", 0) + bytes(8) + u32(1) + name(b"synthetic-bone\0") + u32(0) + matrix()
    return data + b"".join(children)


def material(label=b"material\0", values=None):
    if values is None: values = [-0.25 - i * 0.125 for i in range(16)] + [7.5]
    data = name(label) + struct.pack("<17f", *values)
    for i in range(8):
        if i == 4: data += bytes(4)
        data += name(b"checker.bmp\0" if i == 0 else b"") + bytes(16)
    return data + bytes(4)


def bmp():
    pixels = b"\x1e\x14\x0a\0"
    return b"\0\0" + struct.pack("<IHHI", 58, 0, 0, 54) + struct.pack("<IiiHHIIiiII", 40, 1, 1, 1, 24, 0, 4, 0, 0, 0, 0) + pixels


def tga():
    return struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, 1, 1, 32, 0x28) + bytes((30, 20, 10, 40))


def fixture(uv_sets=0, material_names=(b"material\0", b"second\0"), depth=1, images=None):
    tree = node(uv_sets=uv_sets)
    for _ in range(depth): tree = node((tree,))
    data = u32(0x404c28f6) + bytes(17) + tree + bytes(4) + u32(len(material_names))
    data += b"".join(material(label) for label in material_names)
    if images is None: images = ((b"checker.bmp\0", bmp()), (b"checker.tga\0", tga()))
    data += u32(len(images))
    for label, payload in images:
        data += name(label) + bytes(33) + u32(len(payload)) + payload
    return data


def diagnostic_fixture():
    # Top-down 2x2 BGR checker in an XX-embedded, zero-signature BMP.
    pixels = bytes((40, 80, 255, 100, 220, 40, 0, 0, 255, 100, 40, 100, 230, 250, 0, 0))
    image = b"\0\0" + struct.pack("<IHHI", 70, 0, 0, 54)
    image += struct.pack("<IiiHHIIiiII", 40, 2, -2, 1, 24, 0, 16, 0, 0, 0, 0) + pixels
    return fixture(material_names=(b"diagnostic\0",), images=((b"checker.bmp\0", image),))


def material_tables():
    for count in (0, 1, 3):
        for pattern in range(3):
            values = [[(-0.0 if j % 2 else 0.0) for j in range(17)],
                      [-0.125 - j * 0.25 for j in range(17)],
                      [(-1 if j % 2 else 1) * (0.3 + j * 1.7) for j in range(17)]][pattern]
            table = bytes(4) + u32(count) + b"".join(material(("mat-%d" % i).encode() + b"\0", values) for i in range(count))
            data = u32(0x404c28f6) + bytes(17) + node() + table + u32(0)
            yield count, pattern, table, data
