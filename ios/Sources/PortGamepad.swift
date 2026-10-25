import SwiftUI

// The UIKit control layer is adapted from weixing3's actual DmGamepad.m.
// It owns all fingers and GameController events; sample only once per rendered
// frame so a short press cannot disappear between display-link callbacks.
final class PortGamepad {
    func sample() -> dc_pad_frame { dc_gamepad_read() }
    func setActive(_ active: Bool) { dc_gamepad_set_active(active) }
}

struct PortVirtualGamepad: UIViewRepresentable {
    func makeUIView(context: Context) -> DCGamepadView {
        DCGamepadView(frame: .zero)
    }
    func updateUIView(_ view: DCGamepadView, context: Context) {}
    static func dismantleUIView(_ view: DCGamepadView, coordinator: ()) { view.reset() }
}
