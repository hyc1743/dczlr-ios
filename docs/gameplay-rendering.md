# Gameplay rendering correction

The original gameplay checks established successful submission and animation,
but did not establish that a complete character was visible. The device capture
exposed back-facing room geometry occluding the actor and an incorrect face
attachment. The repaired path retains the original CAM values, including signed
distance and wrapped angles; the speculative scene camera overrides were removed.

Geometry draws now explicitly select framebuffer front-face winding. Two-sided
sprites and startup geometry keep their existing default. The same Vulkan pixel
gate checks both windings and restoration to two-sided rendering.

The PLST attachment maps the face source anchor to an animated body neck anchor.
The original binding preserves the source bind transform and compensates the
target bind transform. For this face hierarchy, the equivalent model world is
`inverse(bodyNeckBindGlobal) * bodyNeckAnimatedGlobal`. Passing the animated neck
directly as the face model world added the bind offset again. The shared affine
inverse and a synthetic attachment regression guard this behavior.

Normal chapter initialization also hides alternate outfits and facial effect
meshes. Runtime node visibility reproduces those verified initialization flags;
descendants inherit the parent flag. Optional randomized outfit branches are not
assumed without saved-state evidence.

Movement preserves the initial root-to-floor offset. A model's origin is not its
feet: setting root Y directly to floor Y sinks the actor. Ground queries use the
existing floor reference, and camera tracking follows the full player displacement.

Validation includes native model regressions, actual Vulkan winding/depth pixel
readback, a local real-resource GPU comparison and a capture of the first native
iOS gameplay frame before scripted interaction. The simulator probe requires a
bounded visible outfit area in that first frame in addition to gameplay markers.
This is a visibility gate, not a claim of complete original rendering equivalence.
