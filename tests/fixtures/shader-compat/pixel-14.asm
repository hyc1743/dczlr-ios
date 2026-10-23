// Self-authored PortLab pixel shader 1.4 texture and source-modifier regression.
ps_1_4
texld r0, t0
texld r1, t1
mul r0, r0_bx2, r1
