"""Self-authored XA framing and numeric-table fixtures; no original payloads."""
import struct


def u32(value):
    return struct.pack("<I", value)


def block(value):
    return u32(len(value)) + value


def clip_table():
    patterns = (0, 0x80000000, 0x3f800000, 0x7f800000, 0xff800000,
                0x7fc12345, 1, 0x7f7fffff, 0x7fa12345)
    result = bytearray()
    for index in range(512):
        record = bytearray(108)
        name = ("synthetic-%03d" % index).encode()
        record[:64] = bytes(value ^ 255 for value in name.ljust(64, b"\0"))
        for field, shift in ((64, 0), (68, 1), (72, 2), (76, 3)):
            struct.pack_into("<I", record, field, patterns[(index + shift) % len(patterns)])
        record[80:83] = bytes(((index * 3) % 256, (index * 7) % 256, (index * 11) % 256))
        struct.pack_into("<I", record, 83, (index * 0x10204081) & 0xffffffff)
        record[87] = (index * 13) % 256
        struct.pack_into("<I", record, 88, (index * 0x80402011) & 0xffffffff)
        record[92:108] = bytes((index + j) % 256 for j in range(16))
        result.extend(record)
    return bytes(result)


def numeric_reference(table):
    """Independent serialized-field copies; deliberately avoid float arithmetic."""
    clips, timing = bytearray(), bytearray()
    for offset in range(0, len(table), 108):
        record = table[offset:offset + 108]
        clips.extend(record[72:80] + record[88:92] + bytes((record[80], 0, record[87], 0)))
        timing.extend(record[64:68] + record[83:87] + bytes((record[81], record[82], 0, 0)))
    return bytes(clips), bytes(timing)


def fixture(all_sections=True, has_clips=True, table=None):
    data = bytearray()
    if all_sections:
        data += b"\1" + u32(1) + block(b"material\0") + u32(2) + bytes(range(144))
        data += b"\1" + u32(1) + u32(7) + block(b"event\0") + bytes(range(8))
        data += u32(2) + bytes(range(10)) + bytes(range(5))
        data += b"\1" + u32(1) + b"\1" + u32(2) + bytes(range(8)) + block(b"indexset\0")
        data += u32(1) + u32(2) + bytes(range(48)) + block(b"vectors\0")
        data += u32(1) + block(b"morph\0") + block(b"indexset\0")
        data += u32(1) + bytes(range(6)) + block(b"vectors\0") + u32(9)
    else:
        data += b"\0" * 3
    data += bytes((int(has_clips),))
    offset = len(data) if has_clips else 0
    if has_clips:
        data += clip_table() if table is None else table
        if all_sections:
            data += u32(1) + block(b"bone\0") + u32(2) + u32(0) + bytes(range(104))
        else:
            data += u32(0)
    return bytes(data), offset


def looping_fixture():
    table = bytearray(512 * 108)
    struct.pack_into("<f", table, 64, 1.0)
    struct.pack_into("<f", table, 76, 8.0)
    table[80] = 1
    return fixture(all_sections=False, table=table)[0]
