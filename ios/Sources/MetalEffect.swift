import Metal

struct ConvertedEffect {
    let id: ResourceId
    let pipeline: MTLRenderPipelineState
    let depthStencil: MTLDepthStencilState?
    let blendEnabled: Bool
}

enum MetalEffectError: Error {
    case pipelineCreationFailed(String)
}

/// Builds a known-good test effect while the DX9 bytecode converter is pending.
final class MetalEffectFactory {
    private let device: MTLDevice

    init(device: MTLDevice) { self.device = device }

    func makeSpriteTestEffect(pixelFormat: MTLPixelFormat) throws -> ConvertedEffect {
        do {
            let library = try device.makeLibrary(source: Self.spriteShader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "spriteVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "spriteFragment")
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            let depth = MTLDepthStencilDescriptor()
            depth.isDepthWriteEnabled = false
            depth.depthCompareFunction = .always
            return ConvertedEffect(id: .sprite, pipeline: pipeline,
                                   depthStencil: device.makeDepthStencilState(descriptor: depth),
                                   blendEnabled: true)
        } catch {
            throw MetalEffectError.pipelineCreationFailed(error.localizedDescription)
        }
    }

    private static let spriteShader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Out { float4 position [[position]]; float4 color; };
    vertex Out spriteVertex(uint id [[vertex_id]]) {
        const float2 p[3] = { float2(0, .45), float2(-.45, -.45), float2(.45, -.45) };
        const float4 c[3] = { float4(1, .1, .1, .8), float4(.1, 1, .1, .8), float4(.1, .3, 1, .8) };
        Out out; out.position = float4(p[id], 0, 1); out.color = c[id]; return out;
    }
    fragment float4 spriteFragment(Out in [[stage_in]]) { return in.color; }
    """
}
