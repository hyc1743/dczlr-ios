import Foundation
import GameController
import SwiftUI

enum PortGameButton: Hashable { case a, b, x, y, leftShoulder, rightShoulder }

struct PortGamepadState: Equatable {
    var leftX: Float = 0; var leftY: Float = 0
    var dpadX: Float = 0; var dpadY: Float = 0
    var rightX: Float = 0; var rightY: Float = 0
    var buttonA = false; var buttonB = false; var buttonX = false; var buttonY = false
    var leftShoulder = false; var rightShoulder = false
    var actionPressed = false; var connected = false
}

final class PortGamepad: ObservableObject {
    @Published private(set) var state = PortGamepadState()
    private var observers: [NSObjectProtocol] = []
    private weak var controller: GCController?
    private var physical = PortGamepadState()
    private var virtualLeft = CGPoint.zero, virtualDpad = CGPoint.zero, virtualRight = CGPoint.zero
    private var virtualButtons = Set<PortGameButton>()

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Notification.Name.GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.selectController() })
        observers.append(center.addObserver(forName: Notification.Name.GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.selectController() })
        GCController.startWirelessControllerDiscovery {}
        selectController()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func selectController() {
        controller = GCController.controllers().first(where: { $0.extendedGamepad != nil })
        physical = PortGamepadState(connected: controller != nil)
        guard let pad = controller?.extendedGamepad else { recompute(); return }
        pad.valueChangedHandler = { [weak self] pad, _ in DispatchQueue.main.async { self?.sample(pad) } }
        sample(pad)
    }

    private func sample(_ pad: GCExtendedGamepad) {
        physical.connected = true
        physical.leftX = pad.leftThumbstick.xAxis.value; physical.leftY = pad.leftThumbstick.yAxis.value
        physical.dpadX = pad.dpad.xAxis.value; physical.dpadY = pad.dpad.yAxis.value
        physical.rightX = pad.rightThumbstick?.xAxis.value ?? 0; physical.rightY = pad.rightThumbstick?.yAxis.value ?? 0
        physical.buttonA = pad.buttonA.isPressed; physical.buttonB = pad.buttonB.isPressed
        physical.buttonX = pad.buttonX.isPressed; physical.buttonY = pad.buttonY.isPressed
        physical.leftShoulder = pad.leftShoulder.isPressed; physical.rightShoulder = pad.rightShoulder.isPressed
        recompute()
    }

    private func recompute() {
        var result = physical
        result.leftX = abs(physical.leftX) > 0.08 ? physical.leftX : Float(virtualLeft.x)
        result.leftY = abs(physical.leftY) > 0.08 ? physical.leftY : Float(virtualLeft.y)
        result.dpadX = abs(physical.dpadX) > 0.08 ? physical.dpadX : Float(virtualDpad.x)
        result.dpadY = abs(physical.dpadY) > 0.08 ? physical.dpadY : Float(virtualDpad.y)
        result.rightX = abs(physical.rightX) > 0.08 ? physical.rightX : Float(virtualRight.x)
        result.rightY = abs(physical.rightY) > 0.08 ? physical.rightY : Float(virtualRight.y)
        result.buttonA = physical.buttonA || virtualButtons.contains(.a); result.buttonB = physical.buttonB || virtualButtons.contains(.b)
        result.buttonX = physical.buttonX || virtualButtons.contains(.x); result.buttonY = physical.buttonY || virtualButtons.contains(.y)
        result.leftShoulder = physical.leftShoulder || virtualButtons.contains(.leftShoulder)
        result.rightShoulder = physical.rightShoulder || virtualButtons.contains(.rightShoulder)
        result.actionPressed = result.buttonA || result.buttonB || result.buttonX || result.buttonY
        state = result
    }
    func setVirtualLeft(x: Float, y: Float) { virtualLeft = CGPoint(x: x, y: y); recompute() }
    func setVirtualDpad(x: Float, y: Float) { virtualDpad = CGPoint(x: x, y: y); recompute() }
    func setVirtualRight(x: Float, y: Float) { virtualRight = CGPoint(x: x, y: y); recompute() }
    func setVirtualButton(_ button: PortGameButton, pressed: Bool) { if pressed { virtualButtons.insert(button) } else { virtualButtons.remove(button) }; recompute() }
}

struct PortVirtualGamepad: View {
    @ObservedObject var input: PortGamepad
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PortVirtualStick(input: input, kind: .left).frame(width: 154, height: 154).position(x: 108, y: geometry.size.height - 118)
                PortVirtualDpad(input: input).frame(width: 112, height: 112).position(x: 260, y: geometry.size.height - 112)
                PortVirtualStick(input: input, kind: .right).frame(width: 104, height: 104).position(x: geometry.size.width - 270, y: geometry.size.height - 104)
                PortVirtualFaceButtons(input: input).frame(width: 154, height: 154).position(x: max(188, geometry.size.width - 108), y: geometry.size.height - 120)
                HStack { PortVirtualHoldButton(label: "L", button: .leftShoulder, input: input); Spacer(); PortVirtualHoldButton(label: "R", button: .rightShoulder, input: input) }
                    .padding(.horizontal, 28).padding(.top, 26).frame(maxHeight: .infinity, alignment: .top)
            }.foregroundStyle(.white).allowsHitTesting(true)
        }.ignoresSafeArea().opacity(input.state.connected ? 0.28 : 0.52)
    }
}

private enum PortStickKind { case left, right }
private struct PortVirtualStick: View {
    @ObservedObject var input: PortGamepad; let kind: PortStickKind; @State private var knob = CGPoint.zero
    var body: some View {
        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) / 2
            ZStack { Circle().fill(.black.opacity(0.34)).overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 1)); Circle().fill(.white.opacity(0.28)).frame(width: radius * 0.58, height: radius * 0.58).offset(knob) }
                .contentShape(Circle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let c = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2), dx = value.location.x - c.x, dy = value.location.y - c.y, maxTravel = radius * 0.42, length = max(1, sqrt(dx * dx + dy * dy)), scale = min(1, maxTravel / length)
                    knob = CGPoint(x: dx * scale, y: dy * scale); let x = Float(knob.x / maxTravel), y = Float(-knob.y / maxTravel)
                    if kind == .left { input.setVirtualLeft(x: x, y: y) } else { input.setVirtualRight(x: x, y: y) }
                }.onEnded { _ in knob = .zero; if kind == .left { input.setVirtualLeft(x: 0, y: 0) } else { input.setVirtualRight(x: 0, y: 0) } })
        }
    }
}

private struct PortVirtualDpad: View {
    @ObservedObject var input: PortGamepad
    var body: some View { GeometryReader { geometry in
        Circle().fill(.black.opacity(0.3)).overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 1)).overlay(Image(systemName: "plus").font(.system(size: 55, weight: .bold)).foregroundStyle(.white.opacity(0.35)))
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in let c = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2), dx = value.location.x - c.x, dy = c.y - value.location.y, length = max(1, sqrt(dx * dx + dy * dy)); input.setVirtualDpad(x: Float(dx / length), y: Float(dy / length)) }.onEnded { _ in input.setVirtualDpad(x: 0, y: 0) })
    } }
}

private struct PortVirtualFaceButtons: View {
    @ObservedObject var input: PortGamepad
    var body: some View { ZStack { PortVirtualHoldButton(label: "Y", button: .y, input: input).offset(y: -42); PortVirtualHoldButton(label: "A", button: .a, input: input).offset(y: 42); PortVirtualHoldButton(label: "X", button: .x, input: input).offset(x: -42); PortVirtualHoldButton(label: "B", button: .b, input: input).offset(x: 42) } }
}

private struct PortVirtualHoldButton: View {
    let label: String; let button: PortGameButton; @ObservedObject var input: PortGamepad
    var body: some View { Text(label).font(.system(size: 16, weight: .bold)).frame(width: 48, height: 48).background(.black.opacity(0.48), in: Circle()).overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1)).contentShape(Circle()).gesture(DragGesture(minimumDistance: 0).onChanged { _ in input.setVirtualButton(button, pressed: true) }.onEnded { _ in input.setVirtualButton(button, pressed: false) }) }
}
