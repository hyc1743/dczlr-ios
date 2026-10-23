// Self-authored PortLab legacy texture-matrix and signed-source regression.
ps_1_1
tex t0
texm3x2pad t1, t0_bx2
texm3x2tex t2, t0_bx2
mov r0, t2
