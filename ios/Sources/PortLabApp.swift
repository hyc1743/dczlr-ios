import SwiftUI

@main
struct PortLabApp: App {
    @StateObject private var model = LabModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("iOS 平台测试").font(.headline)
                Text("自制测试场景 · 拖动画面移动三角形").font(.caption)
                GeometryReader { geometry in
                    MetalSurface(model: model)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                            guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                            model.x = Float(min(1, max(-1, 2 * event.location.x / geometry.size.width - 1)))
                            model.y = Float(min(1, max(-1, 1 - 2 * event.location.y / geometry.size.height)))
                        })
                }
                HStack {
                    Button("播放测试音") { model.playTone() }
                    Button("保存位置") { model.save() }
                    Button("读取位置") { model.load() }
                }.buttonStyle(.bordered)
                Text(model.status).font(.caption).accessibilityIdentifier("labStatus")
                Text("测试日志与位置文件保存在本机 Documents 目录。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
            .onChange(of: phase) { newPhase in
                model.setActive(newPhase == .active)
            }
        }
    }
}
