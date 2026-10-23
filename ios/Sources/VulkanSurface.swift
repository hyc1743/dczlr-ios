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
    private var reportedAnimationAdvance = false
    private var reportedMaterialAdvance = false
    private var reportedPoseAdvance = false
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
            touching: model.touchActive) { [weak self] error, device, scene, animationAdvanced, materialAdvanced, poseAdvanced in
                guard let self = self else { return }
                self.renderPending = false
                if let error = error {
                    self.failed = true
                    self.displayLink?.isPaused = true
                    self.model.record("Vulkan 初始化或绘制失败：\(error)")
                    return
                }
                if self.lastReportedScene != scene {
                    self.lastReportedScene = scene
                    switch scene {
                    case .diagnostic:
                        self.model.record("Vulkan / MoltenVK 已显示自制检查精灵（\(device)）", event: "PORTLAB_SCENE_PRESENTED=checker")
                    case .startupCard:
                        self.model.record("Vulkan / MoltenVK 已呈现第一张启动卡与过场（\(device)）", event: "PORTLAB_SCENE_PRESENTED=startup")
                    case .startupWarning:
                        self.model.record("Vulkan / MoltenVK 已呈现第二张启动卡与过场（\(device)）", event: "PORTLAB_SCENE_PRESENTED=warning")
                    case .startupTransition:
                        self.model.record("启动过场模型已完成呈现", event: "PORTLAB_STARTUP_TRANSITION_PRESENTED")
                    case .title:
                        self.model.record("双卡启动状态已完成并进入标题呈现", event: "PORTLAB_STARTUP_COMPLETED")
                        self.model.record("Vulkan / MoltenVK 已显示标题画面（\(device)）；后续游戏逻辑尚未接入", event: "PORTLAB_SCENE_PRESENTED=title")
                    @unknown default:
                        self.model.record("Vulkan 返回未知场景编号：\(scene.rawValue)")
                    }
                }
                if scene == .diagnostic, animationAdvanced, !self.reportedAnimationAdvance {
                    self.reportedAnimationAdvance = true
                    self.model.record("自制 XX 纹理解码及 XA 材质绑定已完成呈现", event: "PORTLAB_NATIVE_XX_FIXTURE_LOADED")
                    self.model.record("自制 XA 数据已通过原生读取并用于动画更新", event: "PORTLAB_NATIVE_XA_FIXTURE_LOADED")
                    self.model.record("原生 XA 读取与动画更新已推进精灵旋转并完成呈现", event: "PORTLAB_NATIVE_ANIMATION_ADVANCED")
                }
                if scene == .diagnostic, materialAdvanced, !self.reportedMaterialAdvance {
                    self.reportedMaterialAdvance = true
                    self.model.record("原生 XA 材质采样已改变精灵透明度并完成呈现", event: "PORTLAB_NATIVE_MATERIAL_ADVANCED")
                }
                if scene == .diagnostic, poseAdvanced, !self.reportedPoseAdvance {
                    self.reportedPoseAdvance = true
                    self.model.record("原生 XA 节点姿态已改变精灵变换并完成呈现", event: "PORTLAB_NATIVE_POSE_ADVANCED")
                }
            }
    }
}
