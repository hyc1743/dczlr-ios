import QuartzCore
import SwiftUI

struct VulkanSurface: UIViewRepresentable {
    @ObservedObject var model: LabModel

    func makeCoordinator() -> SpritePresenter { SpritePresenter(model: model) }

    func makeUIView(context: Context) -> DCVulkanContainerView {
        let container = DCVulkanContainerView(frame: .zero)
        let view = container.surface
        let realGameplay = ProcessInfo.processInfo.environment["PORTLAB_EXERCISE_REAL_GAMEPLAY"] == "1"
            || ProcessInfo.processInfo.environment["PORTLAB_EXERCISE_STORY"] == "1"
        view.startupDataDirectory = (model.resourcesReady || realGameplay) ? model.gameDataDirectory.path : nil
        container.reservesControls = model.resourcesReady || realGameplay
        context.coordinator.attach(view)
        return container
    }

    func updateUIView(_ container: DCVulkanContainerView, context: Context) {
        let realGameplay = ProcessInfo.processInfo.environment["PORTLAB_EXERCISE_REAL_GAMEPLAY"] == "1"
            || ProcessInfo.processInfo.environment["PORTLAB_EXERCISE_STORY"] == "1"
        container.surface.startupDataDirectory = (model.resourcesReady || realGameplay) ? model.gameDataDirectory.path : nil
        container.reservesControls = model.resourcesReady || realGameplay
        context.coordinator.setActive(model.active)
    }

    static func dismantleUIView(_ view: DCVulkanContainerView, coordinator: SpritePresenter) {
        coordinator.stop()
        view.surface.releaseRenderer()
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
    private var wasGameplay = false
    private var testPadHeld = false
    private var reportedControllerMovement = false
    private var reportedControllerCamera = false
    private var reportedGamepadPresentation: String?
    private var reportedRenderViewport: String?
    private var introChapter = 0
    private var lastIntroRecord: String?
    private var reportedTextFade = false
    private var reportedSkinAdvance = false
    private var reportedGameplaySkinAdvance = false
    private var reportedInteraction = false
    private var touchPositionMode = false
    private var touchSaveObserved = false
    private var reportedTouchStart = false
    private var reportedTouchPass = false
    private var lastGameContext: String?
    private var lastRenderProbeStatus: String?
    private var renderProbeDone = false
    private var mouseEvidence: Set<String> = []
    private var mouseMenuPhase = 0
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
        displayLink?.isPaused = !active || failed || renderProbeDone
        if !active { view?.releaseRenderer() }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private var testingTouch: Bool {
        ProcessInfo.processInfo.environment["PORTLAB_EXERCISE_TOUCH_CONTROLS"] == "1"
    }

    // Drive the visible controls' hit tests and UIKit ownership handlers.
    // No pad axes, button bits or renderer pointer values are fabricated here.
    private func driveTouchRoute() -> Bool {
        let now = CACurrentMediaTime()
        let pulse = now.truncatingRemainder(dividingBy: 1.0) < 0.20
        var ok = true
        switch lastReportedScene {
        case .title:
            ok = dc_gamepad_test_mouse(830, 424, 0, now - (testTitleTime ?? now) > 2 && pulse)
        case .intro:
            ok = dc_gamepad_test_mouse(512, 600, 0, pulse)
        case .gameplay:
            // Exercise independent Num6 + arrow Up while the pointer is moved.
            ok = dc_gamepad_test_key(22, !reportedControllerCamera)
                && dc_gamepad_test_key(11, !reportedControllerCamera)
            // Each stage waits for native state from a presented frame.
            // Select an actual camera context row, dismiss via a fresh right
            // press, then leave the menu open for the final screenshot.
            let leftPhase = mouseMenuPhase == 0 || mouseMenuPhase == 2
            ok = ok && dc_gamepad_test_mouse(0, 0, leftPhase ? 1 : 0, false)
            if mouseMenuPhase == 0 {
                ok = ok && dc_gamepad_test_mouse(968, 376, 0, pulse)
            } else if mouseMenuPhase == 2 {
                ok = ok && dc_gamepad_test_mouse(900, 705, 0, pulse)
            } else if mouseMenuPhase < 6 {
                ok = ok && dc_gamepad_test_mouse(968, 600, 1, pulse)
            } else {
                ok = ok && dc_gamepad_test_mouse(0, 0, 1, false)
            }
        default: return true
        }
        if ok && !reportedTouchStart {
            reportedTouchStart = true
            model.record("Visible mouse buttons and relative drag received UIKit input", event: "PORTLAB_TOUCH_INPUT_STARTED")
        }
        return ok
    }

    @objc private func draw() {
        guard model.active, !failed, !renderProbeDone, !renderPending, let view = view else { return }
        if model.gameResourcesActive {
            let game = view.frame
            let input = view.superview?.bounds.size ?? view.bounds.size
            let viewport = String(format: "input=%.0fx%.0f game=%.3f,%.3f,%.3f,%.3f", input.width, input.height, game.minX, game.minY, game.width, game.height)
            if viewport != reportedRenderViewport {
                reportedRenderViewport = viewport
                model.record(viewport, event: "PORTLAB_RENDER_VIEWPORT")
            }
            let presentation = dc_gamepad_presentation()
            if presentation != reportedGamepadPresentation {
                reportedGamepadPresentation = presentation
                model.record(presentation, event: "PORTLAB_GAMEPAD_PRESENTATION")
            }
        }
        renderPending = true
        if testingTouch && !driveTouchRoute() {
            failed = true
            displayLink?.isPaused = true
            model.record("Touch input could not reach its visible control", event: "PORTLAB_TOUCH_ROUTE_FAILED")
            return
        }
        var pad = model.gamepad.sample()
        let pcInput = dc_pc_input_read()
        var pointerX = model.x, pointerY = model.y
        var touching = model.touchActive
        if pad.touch_count > 0 {
            pointerX = pad.touch_x * 2 - 1
            pointerY = 1 - pad.touch_y * 2
            touching = true
        }
        // CI supplies generated resources and exercises the same menu input
        // adapter. Normal launches continue to use the user's pointer state.
        if !testingTouch, ProcessInfo.processInfo.environment["PORTLAB_EXERCISE_NEW_GAME"] == "1",
           let titleTime = testTitleTime, lastReportedScene == .title {
            let elapsed = CACurrentMediaTime() - titleTime
            let scale = min(view.bounds.width / 1024, view.bounds.height / 768)
            let px = (view.bounds.width - 1024 * scale) / 2 + 830 * scale
            let py = (view.bounds.height - 768 * scale) / 2 + 424 * scale
            pointerX = Float(2 * px / view.bounds.width - 1)
            pointerY = Float(1 - 2 * py / view.bounds.height)
            touching = elapsed >= 6 && elapsed < 6.4
        }
        if !testingTouch, ProcessInfo.processInfo.environment["PORTLAB_EXERCISE_STORY"] == "1" {
            if lastReportedScene == .title, let titleTime = testTitleTime {
                // Same New Game activation as the generated-resource exercise.
                let elapsed = CACurrentMediaTime() - titleTime
                let scale = min(view.bounds.width / 1024, view.bounds.height / 768)
                let px = (view.bounds.width - 1024 * scale) / 2 + 830 * scale
                let py = (view.bounds.height - 768 * scale) / 2 + 424 * scale
                pointerX = Float(2 * px / view.bounds.width - 1)
                pointerY = Float(1 - 2 * py / view.bounds.height)
                touching = elapsed >= 6 && elapsed < 6.4
            } else if lastReportedScene == .intro {
                // Advance every numbered script chapter with a short tap.
                let elapsed = CACurrentMediaTime() - (testIntroTime ?? CACurrentMediaTime())
                touching = elapsed.truncatingRemainder(dividingBy: 1.0) < 0.18
            } else if lastReportedScene == .gameplay {
                if testGameplayTime == nil { testGameplayTime = CACurrentMediaTime() }
                let elapsed = CACurrentMediaTime() - (testGameplayTime ?? CACurrentMediaTime())
                let cycle = elapsed.truncatingRemainder(dividingBy: 6.0)
                let scale = min(view.bounds.width / 1024, view.bounds.height / 768)
                let px: CGFloat
                let py: CGFloat
                if cycle < 2 {
                    // Touch interaction row 2 at (968, 488).
                    px = (view.bounds.width - 1024 * scale) / 2 + 968 * scale
                    py = (view.bounds.height - 768 * scale) / 2 + 488 * scale
                } else if cycle < 4 {
                    // Finish row 4 at (968, 712).
                    px = (view.bounds.width - 1024 * scale) / 2 + 968 * scale
                    py = (view.bounds.height - 768 * scale) / 2 + 712 * scale
                } else {
                    // Chapter-end advance row 1 at (968, 376).
                    px = (view.bounds.width - 1024 * scale) / 2 + 968 * scale
                    py = (view.bounds.height - 768 * scale) / 2 + 376 * scale
                }
                pointerX = Float(2 * px / view.bounds.width - 1)
                pointerY = Float(1 - 2 * py / view.bounds.height)
                touching = cycle.truncatingRemainder(dividingBy: 1.0) < 0.22
            }
        }
        if !testingTouch, ProcessInfo.processInfo.environment["PORTLAB_EXERCISE_NEW_GAME"] == "1",
           let introTime = testIntroTime, lastReportedScene == .intro, introChapter == 0 {
            let elapsed = CACurrentMediaTime() - introTime
            touching = (elapsed >= 2 && elapsed < 2.2) ||
                (elapsed >= 3 && elapsed < 3.2) ||
                (elapsed >= 4 && elapsed < 4.2) ||
                (elapsed >= 5 && elapsed < 5.2)
        }
        if !testingTouch, ProcessInfo.processInfo.environment["PORTLAB_EXERCISE_REAL_GAMEPLAY"] == "1",
           let introTime = testIntroTime, lastReportedScene == .intro {
            let elapsed = CACurrentMediaTime() - introTime
            touching = elapsed >= 2 && elapsed.truncatingRemainder(dividingBy: 1.0) < 0.2
        }
        if !testingTouch, ProcessInfo.processInfo.environment["PORTLAB_EXERCISE_REAL_GAMEPLAY"] == "1",
           lastReportedScene == .gameplay {
            if !wasGameplay { testGameplayTime = nil }
            if testGameplayTime == nil { testGameplayTime = CACurrentMediaTime() }
            let elapsed = CACurrentMediaTime() - (testGameplayTime ?? CACurrentMediaTime())
            let px = view.bounds.midX
            let py = view.bounds.midY
            pointerX = Float(2 * px / view.bounds.width - 1)
            pointerY = Float(1 - 2 * py / view.bounds.height)
            // Exercise the actual controller boundary, independently of pointer
            // drags. UIKit ownership is covered by the launch regression.
            touching = false
            let held = elapsed >= 1 && (elapsed - 1).truncatingRemainder(dividingBy: 2.5) < 0.22
            pad.buttons = held ? 1 : 0
            pad.pressed = held && !testPadHeld ? 1 : 0
            pad.released = !held && testPadHeld ? 1 : 0
            testPadHeld = held
            // Keep each axis active until its native effect is observed, so a
            // slow first resource frame cannot skip a short timed test window.
            if !reportedControllerMovement { pad.lx = 12000 }
            if !reportedControllerCamera { pad.rx = 10000 }
        }
        wasGameplay = lastReportedScene == .gameplay
        view.requestDraw(atX: pointerX, y: pointerY, time: ProcessInfo.processInfo.systemUptime - start,
            touching: touching, controller: pad, pcInput: pcInput) { [weak self] error, device, scene, animationAdvanced, materialAdvanced, poseAdvanced, musicAdvanced, introState, skinAdvanced, gameplaySkinAdvanced, interactionCompleted in
                guard let self = self else { return }
                self.renderPending = false
                if let context = self.view?.gameplayContext, !context.isEmpty, context != self.lastGameContext {
                    self.lastGameContext = context
                    self.model.record(context, event: "PORTLAB_GAME_SCENE_CONTEXT")
                    if self.testingTouch, !context.contains("menu_events=0") {
                        self.model.record("Pointer click accepted by scene menu at logical (968,376)", event: "PORTLAB_MOUSE_MENU_ACCEPTED")
                        self.mouseEvidence.insert("menu")
                        if self.mouseMenuPhase == 0 { self.mouseMenuPhase = 1 }
                    }
                    if self.testingTouch {
                        let fields = Dictionary(context.split(separator: " ").compactMap { token -> (String, Int)? in
                            let parts = token.split(separator: "=", maxSplits: 1)
                            guard parts.count == 2, let value = Int(parts[1]) else { return nil }
                            return (String(parts[0]), value)
                        }, uniquingKeysWith: { _, new in new })
                        let opened = fields["context_open"] == 1
                        let opens = fields["context_opens"] ?? 0
                        if opened, (fields["context_pixels"] ?? 0) > 100, self.mouseEvidence.insert("context").inserted {
                            self.model.record("Original camera menu rendered with separate GPU visibility evidence", event: "PORTLAB_MOUSE_CONTEXT_RENDERED")
                        }
                        if self.mouseMenuPhase == 1, opened, opens >= 1 { self.mouseMenuPhase = 2 }
                        if self.mouseMenuPhase == 2, (fields["context_selections"] ?? 0) > 0 {
                            self.mouseMenuPhase = 3
                            self.mouseEvidence.insert("selection")
                            self.model.record("Left press selected context index 6; action callback is still pending", event: "PORTLAB_MOUSE_CONTEXT_SELECTED")
                        }
                        if self.mouseMenuPhase == 3, opened, opens >= 2 { self.mouseMenuPhase = 4 }
                        if self.mouseMenuPhase == 4, (fields["context_dismissals"] ?? 0) > 0 {
                            self.mouseMenuPhase = 5
                            self.mouseEvidence.insert("dismiss")
                            self.model.record("A separate right press dismissed the context menu", event: "PORTLAB_MOUSE_CONTEXT_DISMISSED")
                        }
                        if self.mouseMenuPhase == 5, opened, opens >= 3 {
                            self.mouseMenuPhase = 6
                            self.mouseEvidence.insert("finalcontext")
                        }
                    }
                }
                if let status = self.view?.renderProbeStatus, !status.isEmpty, status != self.lastRenderProbeStatus {
                    self.lastRenderProbeStatus = status
                    if status.hasPrefix("completed ") {
                        self.renderProbeDone = true
                        self.displayLink?.isPaused = true
                        self.model.record(status, event: "PORTLAB_RENDER_PROBE_COMPLETED")
                    } else {
                        self.model.record(status, event: "PORTLAB_RENDER_CAPTURE")
                    }
                }
                if self.view?.gameplaySaveCompleted == true, !self.touchSaveObserved {
                    self.touchSaveObserved = true
                    self.model.record("The visible save button wrote the native player/story file", event: "PORTLAB_TOUCH_SAVE_COMPLETED")
                }
                if self.view?.controllerMovementAdvanced == true, !self.reportedControllerMovement {
                    self.reportedControllerMovement = true
                    self.model.record("Controller axes moved the native player", event: "PORTLAB_GAMEPAD_MOVEMENT_ADVANCED")
                }
                if self.view?.controllerCameraAdvanced == true, !self.reportedControllerCamera {
                    self.reportedControllerCamera = true
                    self.model.record("Controller right stick changed the native camera", event: "PORTLAB_GAMEPAD_CAMERA_ADVANCED")
                }
                if error == nil, self.testingTouch, scene == .gameplay {
                    if pcInput.mouse.0 == 3 {
                        self.model.record("Left mouse press delivered to a presented frame", event: "PORTLAB_MOUSE_LEFT_DELIVERED")
                        self.mouseEvidence.insert("left")
                    }
                    if pcInput.mouse.1 == 3 {
                        self.model.record("Right mouse press delivered independently", event: "PORTLAB_MOUSE_RIGHT_DELIVERED")
                        self.mouseEvidence.insert("right")
                    }
                    if pcInput.pointer_active != 0, pcInput.dx != 0 || pcInput.dy != 0 {
                        self.model.record("Relative drag moved the persistent pointer", event: "PORTLAB_MOUSE_MOVE_DELIVERED")
                        self.mouseEvidence.insert("move")
                    }
                    if self.mouseEvidence.isSuperset(of: ["menu", "left", "right", "move", "context", "selection", "dismiss", "finalcontext"]), self.reportedControllerCamera {
                        if self.mouseEvidence.insert("passed").inserted {
                            self.model.record("Bounded virtual mouse input verified; original scene equivalence remains unverified", event: "PORTLAB_MOUSE_INPUT_PASSED")
                        }
                    }
                }
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
                        self.model.record("Vulkan / MoltenVK 已显示标题画面（\(device)）", event: "PORTLAB_SCENE_PRESENTED=title")
                    case .intro:
                        if self.testIntroTime == nil { self.testIntroTime = CACurrentMediaTime() }
                        self.model.record("New-game intro record presented; local chapter 3 scene follows", event: "PORTLAB_SCENE_PRESENTED=intro")
                    case .gameplay:
                        self.model.record("Chapter 3 map and actor scene presented from local game resources", event: "PORTLAB_SCENE_PRESENTED=gameplay")
                    case .gameComplete:
                        self.model.record("Playable map sequence completed", event: "PORTLAB_SCENE_PRESENTED=gameComplete")
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
                if self.testingTouch, scene == .intro, self.introChapter >= 4,
                   self.reportedControllerMovement, self.reportedControllerCamera,
                   self.touchSaveObserved, self.reportedInteraction, !self.reportedTouchPass {
                    self.reportedTouchPass = true
                    self.model.record("Visible touch controls completed selection, position adjustment, camera drag, save and chapter advance",
                                      event: "PORTLAB_TOUCH_ROUTE_PASSED")
                }
            }
    }
}
