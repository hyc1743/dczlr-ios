# RPP04 eyes and neck reader

The two local special-state files use length-prefixed XOR-`0xff` target names,
an explicit record count, the `04pvu` body marker, and fixed total sizes:
326 bytes for `.eyes` and 197 bytes for `.neck`. The native reader validates
the complete framing and exposes the target spans without interpreting the
opaque control body.

`DCGameScene` now requires the eyes profile to contain two targets and five
records, the neck profile to contain one target and three records, and checks
their encoded names against `a_Np_me_R`, `a_Np_me_L`, and `a_Kp_kubi2` before
the scene becomes loaded. The controller values and special renderer behavior
remain a separate reconstruction step; this admission prevents a malformed
auxiliary file from being treated as a valid binding.
