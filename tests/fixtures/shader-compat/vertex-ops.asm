// Self-authored PortLab regression for normalization, interpolation and REP.
vs_2_0
def c0, 1.0, 0.25, 0.5, 0.75
defi i0, 2, 0, 1, 0
dcl_position v0
nrm r0.xyz, v0
lrp r1, c0.y, v0, c0
rep i0
add r1.xyz, r1, r0
endrep
mov oPos, r1
