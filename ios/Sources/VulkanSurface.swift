import QuartzCore
import SwiftUI

struct VulkanSurface: UIViewRepresentable {
    @ObservedObject var model: LabModel

    func makeCoordinator() -> SpritePresenter { SpritePresenter(model: model) }

    func makeUIView(context: Context) -> DCVulkanSpriteView {
        let view = DCVulkanSpriteView(frame: .zero)
        view.startupDataDirectory = model.resourcesReady ? model.gameDataDirectory.path : nil
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: DCVulkanSpriteView, context: Context) {
        view.startupDataDirectory = model.resourcesReady ? model.gameDataDirectory.path : nil
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
    private var reportedMusicAdvance = false
    private var reportedIntroAudioAdvance = false
    private var testTitleTime: CFTimeInterval?
    private var testIntroTime: CFTimeInterval?
    private var testGameplayTime: CFTimeInterval?
    private var introChapter = 0
    private var lastIntroRecord: String?
    private var reportedTextFade = false
    private var reportedSkinAdvance = false
    private var reportedGameplaySkinAdvance = false
    private var reportedInteraction = false
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
        var pointerX = model.x, pointerY = model.y, touching = model.touchActive
        // CI supplies generated resources and exercises the same menu input
        // adapter. Normal launches continue to use the user's pointer state.
        if ProcessInfo.processInfo.environment["PORTLAB_EXERCISE_NEW_GAME"] == "1",
           let titleTime = testTitleTime, lastReportedScene == .title {
            let elapsed = CACurrentMediaTime() - titleTime
            let scale = min(view.bounds.width / 1024, view.bounds.height / 768)
            let px = (view.bounds.width - 1024 * scale) / 2 + 830 * scale
            let py = (view.bounds.height - 768 * scale) / 2 + 424 * scale
            pointerX = Float(2 * px / view.bounds.width - 1)
            pointerY = Float(1 - 2 * py / view.bounds.height)
            touching = elapsed >= 6 && elapsed < 6.4
        }
        if ProcessInfo.processInfo.environment["PORTLAB_EXERCISE_NEW_GAME"] == "1",
           let introTime = testIntroTime, lastReportedScene == .intro, introChapter == 0 {
            let elapsed = CACurrentMediaTime() - introTime
            touching = (elapsed >= 2 && elapsed < 2.2) || (elapsed >= 3 && elapsed < 3.2) || (elapsed >= 4 && elapsed < 4.2)
        }
        if ProcessInfo.processInfo.environment["PORTLAB_EXERCISE_REAL_GAMEPLAY"] == "1",
           lastReportedScene == .gameplay {
            if testGameplayTime == nil { testGameplayTime = CACurrentMediaTime() }
            let elapsed = CACurrentMediaTime() - (testGameplayTime ?? CACurrentMediaTime())
            let px = view.bounds.midX
            let py = view.bounds.midY
            pointerX = Float(2 * px / view.bounds.width - 1)
            pointerY = Float(1 - 2 * py / view.bounds.height)
            touching = elapsed >= 1 && (elapsed - 1).truncatingRemainder(dividingBy: 2.5) < 0.22
        }
        view.requestDraw(atX: pointerX, y: pointerY, time: ProcessInfo.processInfo.systemUptime - start,
            touching: touching) { [weak self] error, device, scene, animationAdvanced, materialAdvanced, poseAdvanced, musicAdvanced, introState, skinAdvanced, gameplaySkinAdvanced, interactionCompleted in
                guard let self = self else { return }
                self.renderPending = false
                if let error = error {
                    self.failed = true
                    self.displayLink?.isPaused = true
                    self.model.gameError = "无法继续运行，请查看应用目录中的 log.txt。"
                    self.model.record("Vulkan 初始化或绘制失败：\(error)")
                    return
                }
                if self.lastReportedScene != scene {
                    self.lastReportedScene = scene
                    if scene != .diagnostic { self.model.gameResourcesActive = true }
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
                        if self.testTitleTime == nil { self.testTitleTime = CACurrentMediaTime() }
                        self.model.record("双卡启动状态已完成并进入标题呈现", event: "PORTLAB_STARTUP_COMPLETED")
                        self.model.record("Vulkan / MoltenVK 已显示标题画面（\(device)）；后续游戏逻辑尚未接入", event: "PORTLAB_SCENE_PRESENTED=title")
                    case .intro:
                        if self.testIntroTime == nil { self.testIntroTime = CACurrentMediaTime() }
                        self.model.record("New-game intro record presented; local chapter 3 scene follows", event: "PORTLAB_SCENE_PRESENTED=intro")
                    case .gameplay:
                        self.model.record("Chapter 3 map and actor scene presented from local game resources", event: "PORTLAB_SCENE_PRESENTED=gameplay")
                    case .gameComplete:
                        self.model.record("Playable map sequence completed", event: "PORTLAB_GAME_COMPLETED")
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
                if scene == .title, musicAdvanced, !self.reportedMusicAdvance {
                    self.reportedMusicAdvance = true
                    self.model.record("标题音乐播放时钟已推进；声音输出仍需设备确认", event: "PORTLAB_TITLE_AUDIO_ADVANCED")
                }
                if scene == .intro, musicAdvanced, !self.reportedIntroAudioAdvance {
                    self.reportedIntroAudioAdvance = true
                    self.model.record("Intro music, sound and voice playback clocks advanced", event: "PORTLAB_INTRO_AUDIO_ADVANCED")
                }
                if scene == .intro {
                    let fields = introState.split(separator: ":")
                    if fields.count == 3, let chapter = Int(fields[0]), let frame = Int(fields[1]), let fade = Int(fields[2]) {
                        self.introChapter = chapter
                        let record = "\(chapter):\(frame)"
                        if record != self.lastIntroRecord {
                            self.lastIntroRecord = record
                            self.model.record("Numbered intro record composited", event: "PORTLAB_INTRO_RECORD=\(record)")
                        }
                        if fade > 0, !self.reportedTextFade {
                            self.reportedTextFade = true
                            self.model.record("Original numeric text fade advanced", event: "PORTLAB_TEXT_FADE_ADVANCED")
                        }
                    }
                }
                if skinAdvanced, !self.reportedSkinAdvance {
                    self.reportedSkinAdvance = true
                    self.model.record("Generated world-space skinned geometry changed and presented", event: "PORTLAB_NATIVE_SKIN_ADVANCED")
                }
                if scene == .gameplay, gameplaySkinAdvanced, !self.reportedGameplaySkinAdvance {
                    self.reportedGameplaySkinAdvance = true
                    self.model.record("Real actor skinning advanced and presented", event: "PORTLAB_GAMEPLAY_SKIN_ADVANCED")
                }
                if interactionCompleted, !self.reportedInteraction {
                    self.reportedInteraction = true
                    self.model.record("Chapter interaction animation completed", event: "PORTLAB_GAME_INTERACTION_COMPLETED")
                }
            }
    }
}
