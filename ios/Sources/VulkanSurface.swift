import QuartzCore
import SwiftUI

struct VulkanSurface: UIViewRepresentable {
    @ObservedObject var model: LabModel

    func makeCoordinator() -> SpritePresenter { SpritePresenter(model: model) }

    func makeUIView(context: Context) -> DCVulkanSpriteView {
        let view = DCVulkanSpriteView(frame: .zero)
        view.startupDataDirectory = model.gameDataDirectory.path
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
    private var lastReportedScene: DCVulkanSpriteScene?
    private var renderPending = false
    private var failed = false
    private let start = ProcessInfo.processInfo.systemUptime

    init(model: LabModel) { self.model = model }

    func attach(_ view: DCVulkanSpriteView) {
        self.view = view
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
        guard model.active, !failed, !renderPending, let view = view else { return }
        renderPending = true
        view.requestDraw(atX: model.x, y: model.y, time: ProcessInfo.processInfo.systemUptime - start,
            touching: model.touchActive) { [weak self] error, device, scene in
                guard let self = self else { return }
                self.renderPending = false
                if let error = error {
                    self.failed = true
                    self.displayLink?.isPaused = true
                    self.model.record("Vulkan 初始化或绘制失败：\(error)")
                } else if self.lastReportedScene != scene {
                    self.lastReportedScene = scene
                    switch scene {
                    case .diagnostic:
                        self.model.record("PORTLAB_SCENE_PRESENTED=checker Vulkan / MoltenVK 已显示自制检查精灵（\(device)）")
                    case .startupCard:
                        self.model.record("PORTLAB_SCENE_PRESENTED=startup Vulkan / MoltenVK 已显示原始 illusion.ema 启动卡（\(device)）")
                    case .title:
                        self.model.record("PORTLAB_SCENE_PRESENTED=title Vulkan / MoltenVK 已显示标题画面（\(device)）；后续游戏逻辑尚未接入")
                    @unknown default:
                        self.model.record("Vulkan 返回未知场景编号：\(scene.rawValue)")
                    }
                }
            }
    }
}
