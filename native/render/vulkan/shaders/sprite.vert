#version 450
// Equivalent shader for the supported XYZRHW/FVF 0x1c4 sprite profile.
layout(location = 0) in vec4 in_position;
layout(location = 1) in uint in_argb;
layout(location = 2) in vec2 in_uv;
layout(location = 0) out vec4 diffuse;
layout(location = 1) out vec2 uv;
layout(push_constant) uniform SpriteConstants {
    vec2 viewport;
    uint alpha_op;
    uint reserved;
} constants;
void main() {
    // D3D9 samples at integer pixel centers, Vulkan at half-integer centers.
    vec2 clip = (in_position.xy + vec2(0.5)) / constants.viewport * 2.0 - 1.0;
    gl_Position = vec4(clip, in_position.z, 1.0);
    diffuse = unpackUnorm4x8(in_argb).bgra;
    uv = in_uv;
}
