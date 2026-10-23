"""Synthetic input matrix shared by offline original-code and portable tests."""
from itertools import product


def cases():
    number = 0
    for cached in (0, 1, 2, 3, 255):
        yield {"cached_mode": cached, "draw": None}
        for mode, hidden, point, software in product(range(4), (0, 1, 2, 255),
                                                     (0, 1, 2, 255), (0, 1, 255)):
            number += 1
            yield {"cached_mode": cached, "draw": {
                "vertex_buffer": 0x13570000 | number,
                "texture": 0 if number % 11 == 0 else 0x24680000 | (number * 7),
                "blend_mode": mode, "hidden": hidden, "point_filter": point,
                "software_vertex": software}}
