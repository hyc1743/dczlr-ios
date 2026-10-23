import QuartzCore
import SwiftUI

struct VulkanSurface: UIViewRepresentable {
    @ObservedObject var model: LabModel

    func makeCoordinator() -> SpritePresenter { SpritePresenter(model: model) }

    func makeUIView(context: Context) -> DCVulkanSpriteView {
        model.record("Vulkan UIView creation")
        let view = DCVulkanSpriteView(frame: .zero)
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: DCVulkanSpriteView, context: Context) {
        context.coordinator.setActive(model.active)
    }

    static func dismantleUIView(_ view: DCVulkanSpriteView, coordinator: SpritePresenter) {
        coordinator.stop()
        view.releaseRenderer()
    }
}

final class SpritePresenter: NSObject {
    private let model: LabModel
    private weak var view: DCVulkanSpriteView?
    private var displayLink: CADisplayLink?
    private var reportedFirstFrame = false
    private var reportedFirstTick = false
    private var failed = false
    private let start = ProcessInfo.processInfo.systemUptime

    init(model: LabModel) { self.model = model }

    func attach(_ view: DCVulkanSpriteView) {
        self.view = view
        model.record("Vulkan display link attached")
        let link = CADisplayLink(target: self, selector: #selector(draw))
        link.preferredFramesPerSecond = 30
        link.isPaused = !model.active
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func setActive(_ active: Bool) {
        displayLink?.isPaused = !active || failed
        if !active { view?.releaseRenderer() }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func draw() {
        guard model.active, !failed, let view = view else { return }
        if !reportedFirstTick {
            reportedFirstTick = true
            model.record("Vulkan display tick; attached=\(view.window != nil), bounds=\(view.bounds)")
        }
        if let error = view.renderSprite(x: model.x, y: model.y, time: ProcessInfo.processInfo.systemUptime - start) {
            failed = true
            displayLink?.isPaused = true
            model.record("Vulkan 初始化或绘制失败：\(error)")
        } else if !reportedFirstFrame && view.presentedFrames > 0 {
            reportedFirstFrame = true
            model.record("Vulkan / MoltenVK 已提交精灵首帧（\(view.deviceName)）；当前为自制渲染测试，游戏尚未接入")
        }
    }
}
