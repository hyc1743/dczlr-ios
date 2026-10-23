// Self-authored PortLab parser fixture. No original game code or resources.
bool blend = true;
int ops[2] = {4, 1};
float gain < string label = "Gain"; > = 0.5;
float4 tint = float4(0.25, 0.5, 0.75, 1.0);
texture decal;
sampler2D base = sampler_state {
    Texture = <decal>;
    AddressU = Clamp;
    AddressV = Wrap;
    MinFilter = Linear;
    MagFilter = Point;
};
float4 vertex(float4 position : POSITION) : POSITION { return position; }
float4 shifted(float4 position : POSITION) : POSITION { position.x += 1.0; return position; }
float4 pixel(float2 uv : TEXCOORD0) : COLOR0 { return tint * gain; }
int variant = 1;
vertexshader variants[2] = {compile vs_2_0 vertex(), compile vs_2_0 shifted()};
technique Synthetic {
    pass Fixed {
        VertexShader = NULL;
        PixelShader = NULL;
        AlphaBlendEnable = <blend>;
        SrcBlend = SrcAlpha;
        DestBlend = InvSrcAlpha;
        Sampler[0] = <base>;
        ColorOp[0] = <ops[0]>;
        ColorArg1[0] = Texture;
        ColorArg2[0] = Diffuse;
    }
    pass Shaded {
        VertexShader = <variants[variant]>;
        PixelShader = compile ps_2_0 pixel();
    }
}
