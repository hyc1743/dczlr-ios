# Camera matrix profile

`dc_camera_build` reconstructs the matrix calculation in the two original
orbit controllers, `0x4656c0` and `0x4790d0`. Both use row vectors:

```
world = Tz(-stored_distance) * Rx(pitch) * Ry(yaw) * Ty(height) * base
view = inverse(world)
projection = PerspectiveFovRH(fov, viewport_width / viewport_height, near, far)
view_projection = view * projection
```

The serialized distance is copied as stored; preset selection does not negate
it. The separate controller initializer negates its distance argument before
storing it. The API accepts the stored value explicitly to avoid conflating
these two operations. Angles are radians. Projection uses D3D depth `[0,1]`.

Inputs must be finite, the base affine and invertible, the viewport nonzero,
and `0 < fov < pi`, `0 < near < far`. Invalid inputs preserve all four output
matrices. Input/output aliasing is supported. This API does not apply mouse
limits, collision, tracking, character attachment or rendering state.

`dc_camera_read_preset` decodes the observed CAM profiles: 28 or 252 bytes,
containing one or nine little-endian records of seven floats. Each record is
height, stored distance, pitch, yaw and XYZ base translation. All records must
be finite. The original 252-byte game table selector addresses records 0, 3
and 6 using an 84-byte stride; the other records remain individually readable
without assigning an unverified controller role to them.

`tools/oracle_camera.py` runs only the two bounded original orbit bodies and
the projection body in Unicorn. D3DX43 math and device publication/viewport
calls are explicit host-reference or synthetic boundaries. The public fixture
contains 108 self-authored inputs, with 216 original orbit and 216 projection
calls. Maximum absolute errors are approximately `3.82e-6` for world,
`1.53e-5` for view, `1.91e-6` for projection and `6.11e-5` for view-projection.
Every element must satisfy the fixture's relative/absolute tolerance.

A separate local audit decoded all 81 recognized CAM files (529 records) and
compared their numeric matrices with the isolated original driver/reference
math. Its report contains only counts, hashes and error bounds and stays
outside the public repository. No original preset values or media are shipped
in fixtures. This evidence does not establish the full scene initializer's
selected camera, GPU output or game playability. The separate
`dc_mesh_clip_project` interface now handles nonpositive-W and near-plane
intersections; depth, original material/lighting state and complete scene
initialization remain unfinished.
