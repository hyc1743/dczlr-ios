#version 450
layout(set = 0, binding = 0) uniform sampler2D image;
layout(location = 0) in vec4 diffuse;
layout(location = 1) in vec2 uv;
layout(location = 0) out vec4 color;
layout(push_constant) uniform SpriteConstants {
    vec2 viewport;
    uint alpha_op;
    uint reserved;
} constants;
void main() {
    vec4 texel = texture(image, uv);
    color.rgb = texel.rgb * diffuse.rgb;
    if (constants.alpha_op == 4u)
        color.a = texel.a * diffuse.a;
    else if (constants.alpha_op == 2u)
        color.a = texel.a;
    else
        color.a = 1.0; // Admission requires opaque texture and diffuse here.
}
