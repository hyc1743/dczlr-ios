import Foundation
import GameController
import SwiftUI

struct PortGamepadState: Equatable {
    var leftX: Float = 0
    var leftY: Float = 0
    var dpadX: Float = 0
    var dpadY: Float = 0
    var actionPressed = false
    var connected = false
}

final class PortGamepad: ObservableObject {
    @Published private(set) var state = PortGamepadState()
    private var observers: [NSObjectProtocol] = []
    private weak var controller: GCController?

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: GCController.didConnectNotification,
                                            object: nil, queue: .main) { [weak self] _ in self?.selectController() })
        observers.append(center.addObserver(forName: GCController.didDisconnectNotification,
                                            object: nil, queue: .main) { [weak self] _ in self?.selectController() })
        GCController.startWirelessControllerDiscovery {}
        selectController()
    }

    deinit {
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
    }

    func selectController() {
        let selected = GCController.controllers().first(where: { $0.extendedGamepad != nil })
        controller = selected
        state.connected = selected != nil
        guard let pad = selected?.extendedGamepad else {
            state.leftX = 0; state.leftY = 0; state.dpadX = 0; state.dpadY = 0
            state.actionPressed = false
            return
        }
        pad.valueChangedHandler = { [weak self] pad, _ in
            DispatchQueue.main.async { self?.sample(pad) }
        }
        sample(pad)
    }

    private func sample(_ pad: GCExtendedGamepad) {
        state.leftX = pad.leftThumbstick.x
        state.leftY = pad.leftThumbstick.y
        state.dpadX = pad.dpad.xAxis.value
        state.dpadY = pad.dpad.yAxis.value
        // Match weixing3's positional diamond: bottom A, right B, left X, top Y.
        state.actionPressed = pad.buttonA.isPressed || pad.buttonB.isPressed
        state.connected = true
    }

    func setVirtualDpad(x: Float, y: Float) {
        state.dpadX = max(-1, min(1, x))
        state.dpadY = max(-1, min(1, y))
    }

    func pulseVirtualAction() {
        state.actionPressed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self else { return }
            if self.controller?.extendedGamepad?.buttonA.isPressed != true &&
                self.controller?.extendedGamepad?.buttonB.isPressed != true {
                self.state.actionPressed = false
            }
        }
    }
}

struct PortVirtualGamepad: View {
    @ObservedObject var input: PortGamepad

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PortVirtualDpad(input: input)
                    .frame(width: 150, height: 150)
                    .position(x: 105, y: geometry.size.height - 105)
                ZStack {
                    PortVirtualButton(label: "Y", input: input).offset(y: -34)
                    PortVirtualButton(label: "A", input: input).offset(y: 34)
                    PortVirtualButton(label: "X", input: input).offset(x: -34)
                    PortVirtualButton(label: "B", input: input).offset(x: 34)
                }
                .frame(width: 130, height: 130)
                .background(.black.opacity(0.2), in: Circle())
                .position(x: max(180, geometry.size.width - 145), y: geometry.size.height - 105)
            }
            .foregroundStyle(.white)
            .allowsHitTesting(true)
        }
        .ignoresSafeArea()
        .opacity(input.state.connected ? 0.28 : 0.5)
    }
}

private struct PortVirtualDpad: View {
    @ObservedObject var input: PortGamepad

    var body: some View {
        GeometryReader { geometry in
            Circle()
                .fill(.black.opacity(0.32))
                .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 1))
                .overlay(Circle().fill(.white.opacity(0.3)).frame(width: 52, height: 52))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        let dx = (value.location.x - center.x) / (geometry.size.width / 2)
                        let dy = (center.y - value.location.y) / (geometry.size.height / 2)
                        let length = max(1, sqrt(dx * dx + dy * dy))
                        input.setVirtualDpad(x: Float(dx / length), y: Float(dy / length))
                    }
                    .onEnded { _ in input.setVirtualDpad(x: 0, y: 0) })
        }
    }
}

private struct PortVirtualButton: View {
    let label: String
    @ObservedObject var input: PortGamepad

    var body: some View {
        Button(label) { input.pulseVirtualAction() }
            .font(.system(size: 16, weight: .bold))
            .frame(width: 46, height: 46)
            .background(.black.opacity(0.45), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
    }
}
