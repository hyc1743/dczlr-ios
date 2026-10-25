import AVFoundation
import Combine
import Foundation

final class LabModel: ObservableObject {
    @Published var x: Float = 0
    @Published var y: Float = 0
    @Published var touchActive = false
    @Published var active = true
    @Published var gameResourcesActive = false
    @Published var gameError: String?
    @Published var resourcesReady = true
    @Published var importingResources = false
    @Published var status = "等待 Vulkan 初始化"
    private var player: AVAudioPlayer?
    private let root: URL
    var gameDataDirectory: URL { root.appendingPathComponent("game/Data", isDirectory: true) }
    private var logReady = false
    private var auditingResources = false

    private struct Position: Codable {
        let version: Int
        let x: Float
        let y: Float
    }

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let current = root.appendingPathComponent("log.txt")
            let previous = root.appendingPathComponent("log.prev.txt")
            if FileManager.default.fileExists(atPath: current.path) {
                let old = try Data(contentsOf: current)
                try old.write(to: previous, options: .atomic)
            }
            try Data().write(to: current, options: .atomic)
            logReady = true
            if let launchID = ProcessInfo.processInfo.environment["PORTLAB_LAUNCH_ID"],
               launchID.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil {
                record("测试程序启动", event: "PORTLAB_SESSION=\(launchID)")
            } else {
                record("测试程序启动")
            }
        } catch {
            status = "日志初始化失败：\(error.localizedDescription)"
        }
        importResourcePacksIfPresent()
    }

    private func importResourcePacksIfPresent() {
        guard !importingResources else { return }
        guard let manifest = Bundle.main.url(forResource: "DczlrData.manifest", withExtension: "json") else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let hasParts = names.contains { $0.hasPrefix("DczlrData.part") && $0.hasSuffix(".dczdata") }
            || ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("ResourcePacks").path)) ?? []).contains { $0.hasSuffix(".dczdata") }
        guard hasParts else { resourcesReady = true; record("未找到资源分卷：(root.path)"); return }
        importingResources = true
        resourcesReady = false
        record("发现资源分卷，开始校验与解包：(root.path)")
        let destination = root.appendingPathComponent("game/Data", isDirectory: true)
        let documentsRoot = root
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try ResourcePackImporter().importPacks(from: documentsRoot, manifestURL: manifest, destination: destination) { completed, total in
                    DispatchQueue.main.async { self?.status = "资源解包：\(completed)/\(total) 字节" }
                }
                DispatchQueue.main.async {
                    self?.importingResources = false
                    self?.resourcesReady = true
                    self?.record("资源分卷解包完成")
                }
            } catch {
                DispatchQueue.main.async {
                    self?.importingResources = false
                    self?.record("资源分卷失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func retryResourceImport() { importResourcePacksIfPresent() }

    func record(_ message: String, event: String? = nil) {
        status = message
        guard logReady else { return }
        do {
            let handle = try FileHandle(forWritingTo: root.appendingPathComponent("log.txt"))
            defer { try? handle.close() }
            try handle.seekToEnd()
            let eventPrefix = event.map { $0 + " " } ?? ""
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(eventPrefix)\(message)\n"
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            status = "\(message)；日志写入失败：\(error.localizedDescription)"
        }
    }

    func save() {
        do {
            let position = Position(version: 1, x: x, y: y)
            try JSONEncoder().encode(position).write(
                to: root.appendingPathComponent("position.json"), options: .atomic)
            record("已保存位置：\(x), \(y)")
        } catch {
            record("保存失败：\(error.localizedDescription)")
        }
    }

    func auditNativeResources() {
        guard !auditingResources else { return }
        auditingResources = true
        record("正在用原生模块检查资源包")
        let directory = root.appendingPathComponent("game/Data", isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: String
            do { result = try NativeResourceAudit.inspect(dataDirectory: directory) }
            catch { result = "原生资源检查失败：" + error.localizedDescription }
            DispatchQueue.main.async {
                self?.auditingResources = false
                self?.record(result)
            }
        }
    }

    func load() {
        do {
            let bytes = try Data(contentsOf: root.appendingPathComponent("position.json"))
            let position = try JSONDecoder().decode(Position.self, from: bytes)
            guard position.version == 1, position.x.isFinite, position.y.isFinite,
                  (-1...1).contains(position.x), (-1...1).contains(position.y) else {
                record("位置文件版本或坐标无效")
                return
            }
            x = position.x
            y = position.y
            record("已读取位置：\(x), \(y)")
        } catch {
            record("读取失败：\(error.localizedDescription)")
        }
    }

    func playTone() {
        guard active else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            player?.stop()
            player = try AVAudioPlayer(data: Self.tone())
            guard player?.play() == true else {
                record("测试音未能开始播放")
                return
            }
            record("已请求播放 440 Hz 测试音；请确认设备是否发声")
        } catch {
            record("音频失败：\(error.localizedDescription)")
        }
    }

    func setActive(_ value: Bool) {
        active = value
        if !value {
            player?.stop()
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                record("音频会话释放失败：\(error.localizedDescription)")
            }
        }
        record(value ? "进入前台，恢复绘制" : "离开前台，暂停绘制与测试音")
    }

    private static func tone() -> Data {
        let sampleRate = 44_100
        let count = sampleRate / 5
        var data = Data()
        func append<T: FixedWidthInteger>(_ number: T) {
            var little = number.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(count * 2))
        for index in 0..<count {
            let edge = min(1.0, Double(min(index, count - 1 - index)) / 220)
            let sample = sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate))
            append(Int16(sample * edge * 6_000))
        }
        return data
    }
}
