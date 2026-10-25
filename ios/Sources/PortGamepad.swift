import Foundation
import GameController
import SwiftUI
import UIKit
import CoreMotion

enum PortGameButton {
    static let a: UInt64 = 1 << 0, b: UInt64 = 1 << 1, x: UInt64 = 1 << 2, y: UInt64 = 1 << 3
    static let leftStick: UInt64 = 1 << 4, rightStick: UInt64 = 1 << 5
    static let left: UInt64 = 1 << 6, right: UInt64 = 1 << 7
    static let zl: UInt64 = 1 << 8, zr: UInt64 = 1 << 9
    static let plus: UInt64 = 1 << 10, minus: UInt64 = 1 << 11
    static let dpadLeft: UInt64 = 1 << 12, dpadUp: UInt64 = 1 << 13
    static let dpadRight: UInt64 = 1 << 14, dpadDown: UInt64 = 1 << 15
    static let shake: UInt64 = 1 << 63
}

struct PortGamepadState: Equatable {
    var buttons: UInt64 = 0
    var leftX: Float = 0, leftY: Float = 0, rightX: Float = 0, rightY: Float = 0
    var dpadX: Float = 0, dpadY: Float = 0
    var touchX: Float = 0, touchY: Float = 0, touchActive = false
    var pressedButtons: UInt64 = 0, releasedButtons: UInt64 = 0
    var connected = false
    var actionPressed: Bool { buttons & (PortGameButton.a | PortGameButton.b | PortGameButton.x | PortGameButton.y) != 0 }
}

final class PortGamepad: ObservableObject {
    @Published private(set) var state = PortGamepadState()
    private var observers: [NSObjectProtocol] = []
    private weak var controller: GCController?
    private var physical = PortGamepadState()
    private var virtualButtons: UInt64 = 0
    private var virtualAxes = (lx: Int32(0), ly: Int32(0), rx: Int32(0), ry: Int32(0))
    private var virtualTouch: (x: Float, y: Float, active: Bool) = (0, 0, false)
    private var previousButtons: UInt64 = 0
    private var motion: CMMotionManager?

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.selectController() })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.selectController() })
        GCController.startWirelessControllerDiscovery {}
        selectController()
        startMotion()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); motion?.stopAccelerometerUpdates() }

    private func startMotion() {
        let manager = CMMotionManager(); guard manager.isAccelerometerAvailable else { return }
        manager.accelerometerUpdateInterval = 1.0 / 60.0
        let threshold = max(0.1, Double(ProcessInfo.processInfo.environment["DM_SHAKE_G"] ?? "1.5") ?? 1.5)
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        var gx = 0.0, gy = 0.0, gz = 0.0, initialized = false, lastHit = -1.0
        manager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let data else { return }; let a = data.acceleration
            if !initialized { gx=a.x; gy=a.y; gz=a.z; initialized=true }
            let dx=a.x-gx, dy=a.y-gy, dz=a.z-gz, magnitude=sqrt(dx*dx+dy*dy+dz*dz)
            gx += (a.x-gx)*0.02; gy += (a.y-gy)*0.02; gz += (a.z-gz)*0.02
            if magnitude > threshold { lastHit = data.timestamp }
            let active = lastHit >= 0 && data.timestamp-lastHit < 0.12
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if active { self.virtualButtons |= PortGameButton.shake } else { self.virtualButtons &= ~PortGameButton.shake }
                self.recompute()
            }
        }
        motion = manager
    }

    func selectController() {
        controller = GCController.controllers().first(where: { $0.extendedGamepad != nil })
        physical = PortGamepadState(connected: controller != nil)
        guard let pad = controller?.extendedGamepad else { recompute(); return }
        pad.valueChangedHandler = { [weak self] pad, _ in DispatchQueue.main.async { self?.sample(pad) } }
        sample(pad)
    }

    private func sample(_ pad: GCExtendedGamepad) {
        physical.connected = true
        var b: UInt64 = 0
        // Match weixing3's positional mapping: bottom A, right B, left X, top Y.
        if pad.buttonB.isPressed { b |= PortGameButton.a }
        if pad.buttonA.isPressed { b |= PortGameButton.b }
        if pad.buttonY.isPressed { b |= PortGameButton.x }
        if pad.buttonX.isPressed { b |= PortGameButton.y }
        if pad.leftShoulder.isPressed { b |= PortGameButton.left }
        if pad.rightShoulder.isPressed { b |= PortGameButton.right }
        if pad.leftTrigger.isPressed { b |= PortGameButton.zl }
        if pad.rightTrigger.isPressed { b |= PortGameButton.zr }
        if pad.buttonMenu.isPressed { b |= PortGameButton.plus }
        if let options = pad.buttonOptions, options.isPressed { b |= PortGameButton.minus }
        if let left = pad.leftThumbstickButton, left.isPressed { b |= PortGameButton.leftStick }
        if let right = pad.rightThumbstickButton, right.isPressed { b |= PortGameButton.rightStick }
        if pad.dpad.left.isPressed { b |= PortGameButton.dpadLeft }
        if pad.dpad.up.isPressed { b |= PortGameButton.dpadUp }
        if pad.dpad.right.isPressed { b |= PortGameButton.dpadRight }
        if pad.dpad.down.isPressed { b |= PortGameButton.dpadDown }
        physical.buttons = b
        physical.leftX = pad.leftThumbstick.xAxis.value; physical.leftY = pad.leftThumbstick.yAxis.value
        physical.rightX = pad.rightThumbstick.xAxis.value; physical.rightY = pad.rightThumbstick.yAxis.value
        physical.dpadX = pad.dpad.xAxis.value; physical.dpadY = pad.dpad.yAxis.value
        recompute()
    }

    private func recompute() {
        var next = physical
        let previous = previousButtons
        next.buttons |= virtualButtons
        next.leftX = abs(physical.leftX) > 0.12 ? physical.leftX : Float(virtualAxes.lx) / 32767
        next.leftY = abs(physical.leftY) > 0.12 ? physical.leftY : Float(virtualAxes.ly) / 32767
        next.rightX = abs(physical.rightX) > 0.12 ? physical.rightX : Float(virtualAxes.rx) / 32767
        next.rightY = abs(physical.rightY) > 0.12 ? physical.rightY : Float(virtualAxes.ry) / 32767
        next.dpadX = physical.dpadX; next.dpadY = physical.dpadY
        if next.dpadX == 0 && next.dpadY == 0 {
            if virtualButtons & PortGameButton.dpadLeft != 0 { next.dpadX -= 1 }
            if virtualButtons & PortGameButton.dpadRight != 0 { next.dpadX += 1 }
            if virtualButtons & PortGameButton.dpadDown != 0 { next.dpadY -= 1 }
            if virtualButtons & PortGameButton.dpadUp != 0 { next.dpadY += 1 }
        }
        next.touchX = virtualTouch.x; next.touchY = virtualTouch.y; next.touchActive = virtualTouch.active
        next.pressedButtons = next.buttons & ~previous
        next.releasedButtons = previous & ~next.buttons
        previousButtons = next.buttons
        state = next
    }

    fileprivate func setVirtual(buttons: UInt64, lx: Int32, ly: Int32, rx: Int32, ry: Int32) {
        virtualButtons = buttons; virtualAxes = (lx, ly, rx, ry); recompute()
    }
    fileprivate func setVirtualTouch(active: Bool, x: Float = 0, y: Float = 0) {
        virtualTouch = (x, y, active); recompute()
    }
    fileprivate func clearVirtual() { setVirtual(buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0); setVirtualTouch(active: false) }
}

struct PortVirtualGamepad: UIViewRepresentable {
    @ObservedObject var input: PortGamepad
    func makeUIView(context: Context) -> PortGamepadView {
        let view = PortGamepadView()
        view.padOff = input.state.connected
        view.onInput = { [weak input] b, lx, ly, rx, ry in input?.setVirtual(buttons: b, lx: lx, ly: ly, rx: rx, ry: ry) }
        view.onTouch = { [weak input] active, x, y in input?.setVirtualTouch(active: active, x: x, y: y) }
        return view
    }
    func updateUIView(_ view: PortGamepadView, context: Context) { view.padOff = input.state.connected; view.setNeedsDisplay() }
    static func dismantleUIView(_ view: PortGamepadView, coordinator: ()) { view.onInput?(0, 0, 0, 0, 0); view.onTouch?(false, 0, 0) }
}

final class PortGamepadView: UIView {
    var onInput: ((UInt64, Int32, Int32, Int32, Int32) -> Void)?
    var onTouch: ((Bool, Float, Float) -> Void)?
    var padOff = false { didSet { if padOff != oldValue { reset() } } }
    private var full = UserDefaults.standard.object(forKey: "PortPadLayout") as? Bool ?? true
    private var owners: [ObjectIdentifier: Owner] = [:]
    private var locations: [ObjectIdentifier: CGPoint] = [:]
    private var faces: [ObjectIdentifier: UInt64] = [:]
    private var sticks: [UITouch?] = [nil, nil]
    private var stickNow = [CGPoint.zero, CGPoint.zero]
    private var rightCentre = CGPoint.zero
    private var gameTouches: [UITouch?] = Array(repeating: nil, count: 16)
    private var held: UInt64 = 0
    private var axes = (Int32(0), Int32(0), Int32(0), Int32(0))
    private enum Kind: Equatable { case button, face, dpad, stick, swap, game }
    private struct Owner { let kind: Kind; let index: Int }

    override init(frame: CGRect) { super.init(frame: frame); isMultipleTouchEnabled = true; backgroundColor = .clear; isOpaque = false }
    required init?(coder: NSCoder) { fatalError("PortGamepadView does not support NSCoder") }
    private var u: CGFloat { min(bounds.height / 430, 1.3) }
    private var corner: CGRect { bounds.inset(by: UIEdgeInsets(top: safeAreaInsets.top, left: safeAreaInsets.left * 0.5, bottom: safeAreaInsets.bottom, right: safeAreaInsets.right * 0.5)) }
    private var safe: CGRect { bounds.inset(by: safeAreaInsets) }
    private var faceCentre: CGPoint { CGPoint(x: corner.maxX - 81 * u, y: corner.maxY - 82 * u) }
    private var stickHome: CGPoint { CGPoint(x: corner.minX + 81 * u, y: corner.maxY - 82 * u) }
    private var dpadCentre: CGPoint { CGPoint(x: corner.minX + 231 * u, y: corner.maxY - 64 * u) }
    private var faceGap: CGFloat { 50 * u }; private var faceRadius: CGFloat { 27 * u }
    private var stickRadius: CGFloat { 77 * u }; private var dpadRadius: CGFloat { 48 * u }
    private func facePoint(_ bit: UInt64) -> CGPoint {
        switch bit { case PortGameButton.a: return CGPoint(x: faceCentre.x + faceGap, y: faceCentre.y); case PortGameButton.b: return CGPoint(x: faceCentre.x, y: faceCentre.y + faceGap); case PortGameButton.x: return CGPoint(x: faceCentre.x - faceGap, y: faceCentre.y); default: return CGPoint(x: faceCentre.x, y: faceCentre.y - faceGap) }
    }
    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private func touchKey(_ t: UITouch) -> ObjectIdentifier { ObjectIdentifier(t) }

    override func draw(_ rect: CGRect) {
        guard !padOff else { return }
        let ctx = UIGraphicsGetCurrentContext()!; ctx.setLineWidth(1.5)
        func circle(_ c: CGPoint, _ r: CGFloat, _ on: Bool, _ label: String? = nil) { ctx.setFillColor(UIColor(white: 1, alpha: on ? 0.45 : 0.14).cgColor); ctx.setStrokeColor(UIColor(white: 1, alpha: 0.38).cgColor); ctx.addEllipse(in: CGRect(x: c.x-r, y: c.y-r, width: 2*r, height: 2*r)); ctx.drawPath(using: .fillStroke); if let label { let a: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 16*u), .foregroundColor: UIColor(white: on ? 0 : 1, alpha: 0.7)]; NSString(string: label).draw(at: CGPoint(x: c.x - 8*u, y: c.y - 8*u), withAttributes: a) } }
        circle(stickHome, stickRadius, sticks[0] != nil); if let t = sticks[0] { let p = stickPoint(stickNow[0], centre: stickHome, radius: stickRadius); circle(p, 30*u, true) }
        if full { circle(dpadCentre, dpadRadius, held & (PortGameButton.dpadLeft|PortGameButton.dpadUp|PortGameButton.dpadRight|PortGameButton.dpadDown) != 0); circle(CGPoint(x: safe.midX, y: safe.minY + 22*u), 15*u, false, "3D") }
        for bit in [PortGameButton.a, PortGameButton.b, PortGameButton.x, PortGameButton.y] { circle(facePoint(bit), faceRadius, held & bit != 0, bit == PortGameButton.a ? "A" : bit == PortGameButton.b ? "B" : bit == PortGameButton.x ? "X" : "Y") }
        let top: [(UInt64, String, CGFloat)] = [(PortGameButton.zl, "ZL", 44), (PortGameButton.left, "L", 44), (PortGameButton.zr, "ZR", bounds.width - 44), (PortGameButton.right, "R", bounds.width - 44), (PortGameButton.minus, "−", bounds.midX - 52*u), (PortGameButton.plus, "+", bounds.midX + 52*u)]
        for (bit, label, x) in top { let y: CGFloat = label == "ZL" || label == "ZR" ? safe.minY + 40*u : label == "L" || label == "R" ? safe.minY + 108*u : safe.minY + 22*u; circle(CGPoint(x: x, y: y), label == "ZL" || label == "ZR" ? 26*u : label == "L" || label == "R" ? 24*u : 14*u, held & bit != 0, label) }
        if full { circle(CGPoint(x: safe.minX + 102*u, y: safe.minY + 40*u), 17*u, held & PortGameButton.leftStick != 0, "L3"); circle(CGPoint(x: safe.maxX - 102*u, y: safe.minY + 40*u), 17*u, held & PortGameButton.rightStick != 0, "R3") }
    }
    private func stickPoint(_ p: CGPoint, centre: CGPoint, radius: CGFloat) -> CGPoint { let dx=p.x-centre.x, dy=p.y-centre.y, d=hypot(dx,dy); guard d > radius else { return p }; return CGPoint(x: centre.x + dx*radius/d, y: centre.y + dy*radius/d) }
    private func axis(_ value: CGFloat, radius: CGFloat) -> Int32 { let dx = value / radius, dead: CGFloat = 0.1; guard abs(dx) > dead else { return 0 }; let fullTilt: CGFloat = 0.8; let n = min((abs(dx)-dead)/(fullTilt-dead), 1) * (dx < 0 ? -1 : 1); return Int32((n * 32767).rounded()) }
    private func emit() { onInput?(held, axes.0, axes.1, axes.2, axes.3) }
    private func gamePoint(_ p: CGPoint) { let w0=bounds.width, h0=bounds.height; var w=w0, h=h0; if w/h > 16/9 { w=h*16/9 } else { h=w*9/16 }; let x0=(w0-w)/2, y0=(h0-h)/2; onTouch?(true, Float(max(0,min(0.999,(p.x-x0)/w))), Float(max(0,min(0.999,(p.y-y0)/h)))) }
    private func gameUpdate() { for (i,t) in gameTouches.enumerated() { if let t { gamePoint(t.location(in: self)); if i == 0 { return } } }; onTouch?(false, 0, 0) }

    private func faceAt(_ p: CGPoint) -> UInt64 { var m: UInt64 = 0; for b in [PortGameButton.a, PortGameButton.b, PortGameButton.x, PortGameButton.y] where dist(p, facePoint(b)) <= faceRadius * 1.25 { m |= b }; return m }
    private func dpadAt(_ p: CGPoint) -> UInt64 { let dx=p.x-dpadCentre.x, dy=p.y-dpadCentre.y; guard hypot(dx,dy) >= dpadRadius*0.25 else { return 0 }; let a=atan2(-dy,dx)*180/.pi; var m: UInt64=0; if a > -67.5 && a < 67.5 {m |= PortGameButton.dpadRight}; if a > 22.5 && a < 157.5 {m |= PortGameButton.dpadUp}; if a > 112.5 || a < -112.5 {m |= PortGameButton.dpadLeft}; if a < -22.5 && a > -157.5 {m |= PortGameButton.dpadDown}; return m }
    private func reset() { owners.removeAll(); locations.removeAll(); faces.removeAll(); sticks=[nil,nil]; gameTouches=Array(repeating:nil,count:16); held=0; axes=(0,0,0,0); emit(); onTouch?(false,0,0); setNeedsDisplay() }
    private func setBit(_ bit: UInt64, _ value: Bool) { if value { held |= bit } else { held &= ~bit } }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        var hasGame = false
        for t in touches {
            let id=touchKey(t), p=t.location(in:self); locations[id] = p
            if padOff { if let i=gameTouches.firstIndex(where:{$0 == nil}) { gameTouches[i]=t; owners[id]=Owner(kind:.game,index:i); hasGame=true }; continue }
            var locked: [(UInt64, CGPoint, CGFloat)] = [(PortGameButton.zl,CGPoint(x:44*u,y:safe.minY+40*u),36*u),(PortGameButton.left,CGPoint(x:44*u,y:safe.minY+108*u),34*u),(PortGameButton.zr,CGPoint(x:bounds.width-44*u,y:safe.minY+40*u),36*u),(PortGameButton.right,CGPoint(x:bounds.width-44*u,y:safe.minY+108*u),34*u),(PortGameButton.minus,CGPoint(x:bounds.midX-52*u,y:safe.minY+22*u),24*u),(PortGameButton.plus,CGPoint(x:bounds.midX+52*u,y:safe.minY+22*u),24*u)]
            if full { locked += [(PortGameButton.leftStick,CGPoint(x:safe.minX+102*u,y:safe.minY+40*u),24*u),(PortGameButton.rightStick,CGPoint(x:safe.maxX-102*u,y:safe.minY+40*u),24*u)] }
            if let hit=locked.first(where:{dist(p,$0.1)<=$0.2}) { owners[id]=Owner(kind:.button,index:Int(hit.0)); setBit(hit.0,true); continue }
            if full && dist(p,CGPoint(x:safe.midX,y:safe.minY+22*u)) <= 24*u { owners[id]=Owner(kind:.swap,index:0); continue }
            var best = 1.0, kind = Kind.game, index = 0
            let f = dist(p, faceCentre) / (faceGap + faceRadius * 1.6)
            if f <= best { best = f; kind = .face }
            if full {
                let d = dist(p, dpadCentre) / (dpadRadius * 1.3)
                if d < best { best = d; kind = .dpad }
            }
            if sticks[0] == nil {
                let s = dist(p, stickHome) / (stickRadius * 1.4)
                if s < best { best = s; kind = .stick; index = 0 }
            }
            if kind == .game && full && sticks[1] == nil && p.x >= bounds.maxX - bounds.width / 3 {
                kind = .stick; index = 1; rightCentre = p
            }
            if kind == .face {owners[id]=Owner(kind:.face,index:0);faces[id]=faceAt(p)} else if kind == .dpad {owners[id]=Owner(kind:.dpad,index:0)} else if kind == .stick {owners[id]=Owner(kind:.stick,index:index);sticks[index]=t;stickNow[index]=p} else if let i=gameTouches.firstIndex(where:{$0 == nil}) {gameTouches[i]=t;owners[id]=Owner(kind:.game,index:i);hasGame=true}
        }
        if hasGame { gameUpdate() }; recompute(); setNeedsDisplay()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { var hasGame=false; for t in touches {let id=touchKey(t),p=t.location(in:self); locations[id] = p; guard let o=owners[id] else{continue};switch o.kind{case .face:faces[id]=faceAt(p);case .stick:stickNow[o.index]=p;if o.index==1{let d=dist(p,rightCentre);if d>60*u{rightCentre=CGPoint(x:p.x-(p.x-rightCentre.x)*60*u/d,y:p.y-(p.y-rightCentre.y)*60*u/d)}};case .game:hasGame=true;default:break}};if hasGame{gameUpdate()};recompute();setNeedsDisplay() }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, tapped:true) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, tapped:false) }
    private func finish(_ touches:Set<UITouch>,tapped:Bool){var swap=false,hasGame=false;for t in touches{let id=touchKey(t);if let o=owners[id]{if tapped && o.kind == .swap && dist(t.location(in:self),CGPoint(x:safe.midX,y:safe.minY+22*u))<=24*u{swap=true};if o.kind == .game{gameTouches[o.index]=nil;hasGame=true};if o.kind == .button{setBit(UInt64(o.index),false)};if o.kind == .face{faces.removeValue(forKey:id)};if o.kind == .stick{sticks[o.index]=nil};owners.removeValue(forKey:id)};locations.removeValue(forKey:id)};if hasGame{gameUpdate()};recompute();if swap{full.toggle();UserDefaults.standard.set(full,forKey:"PortPadLayout")};setNeedsDisplay()}
    private func recompute(){var b=held;for m in faces.values{b |= m};for (id,o) in owners where o.kind == .dpad{b |= dpadAt(locations[id] ?? .zero)};var lx:Int32=0,ly:Int32=0,rx:Int32=0,ry:Int32=0;if sticks[0] != nil{let p=stickPoint(stickNow[0],centre:stickHome,radius:stickRadius);lx=axis(p.x-stickHome.x,radius:stickRadius);ly=axis(-(p.y-stickHome.y),radius:stickRadius)};if sticks[1] != nil{let p=stickPoint(stickNow[1],centre:rightCentre,radius:60*u);rx=axis(p.x-rightCentre.x,radius:60*u);ry=axis(-(p.y-rightCentre.y),radius:60*u)};axes=(lx,ly,rx,ry);onInput?(b,lx,ly,rx,ry)}
}
