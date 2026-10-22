import MetalKit
import SwiftUI

struct MetalSurface: UIViewRepresentable {
    @ObservedObject var model: LabModel

    func makeCoordinator() -> Renderer { Renderer(model: model) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.clearColor = MTLClearColor(red: 0.04, green: 0.06, blue: 0.1, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.isPaused = !model.active
        context.coordinator.configure(view)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        view.isPaused = !model.active
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Renderer) {
        view.isPaused = true
        view.delegate = nil
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    private let model: LabModel
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var firstFrameSubmitted = false
    private let start = ProcessInfo.processInfo.systemUptime

    init(model: LabModel) { self.model = model }

    func configure(_ view: MTKView) {
        guard let device = view.device, let queue = device.makeCommandQueue() else {
            DispatchQueue.main.async { [weak self] in self?.model.record("Metal 设备或队列不可用") }
            return
        }
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "triangleVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "triangleFragment")
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            self.queue = queue
            DispatchQueue.main.async { [weak self] in self?.model.record("Metal 已初始化，等待首帧完成") }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.model.record("Metal 初始化失败：\(error.localizedDescription)")
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard model.active, let pipeline = pipeline, let queue = queue,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        var uniforms = SIMD4<Float>(model.x, model.y,
            Float(ProcessInfo.processInfo.systemUptime - start),
            Float(view.drawableSize.height / max(1, view.drawableSize.width)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        if !firstFrameSubmitted {
            firstFrameSubmitted = true
            command.addCompletedHandler { [weak self] buffer in
                let message = buffer.status == .completed
                    ? "首帧 GPU 命令已完成；请确认屏幕显示彩色三角形"
                    : "首帧 GPU 失败：\(buffer.error?.localizedDescription ?? "未知错误")"
                DispatchQueue.main.async { self?.model.record(message) }
            }
        }
        command.commit()
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Output { float4 position [[position]]; float3 color; };
    vertex Output triangleVertex(uint id [[vertex_id]], constant float4 &u [[buffer(0)]]) {
        const float2 positions[3] = { float2(0, 0.32), float2(-0.28, -0.24), float2(0.28, -0.24) };
        const float3 colors[3] = { float3(1, 0.2, 0.2), float3(0.2, 1, 0.2), float3(0.2, 0.4, 1) };
        float angle = u.z * 0.4;
        float2 p = positions[id];
        p = float2(cos(angle) * p.x - sin(angle) * p.y, sin(angle) * p.x + cos(angle) * p.y);
        Output out;
        out.position = float4(p.x * u.w + u.x, p.y + u.y, 0, 1);
        out.color = colors[id];
        return out;
    }
    fragment float4 triangleFragment(Output in [[stage_in]]) { return float4(in.color, 1); }
    """
}
