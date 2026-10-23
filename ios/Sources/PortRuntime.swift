import Foundation

struct GamePaths {
    let documents: URL
    let data: URL
    let saves: URL
    let logs: URL

    init(fileManager: FileManager = .default) throws {
        documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        data = documents.appendingPathComponent("game/Data", isDirectory: true)
        saves = documents.appendingPathComponent("saves", isDirectory: true)
        logs = documents.appendingPathComponent("log.txt")
        try fileManager.createDirectory(at: data, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: saves, withIntermediateDirectories: true)
    }

    func resolveDataPath(_ relative: String) -> URL? {
        guard !relative.isEmpty, !relative.contains("\\"), !relative.contains("\0") else { return nil }
        let candidate = data.appendingPathComponent(relative)
        let base = data.standardizedFileURL.path
        let path = candidate.standardizedFileURL.path
        guard path == base || path.hasPrefix(base + "/") else { return nil }
        return candidate
    }
}

struct InputSnapshot: Equatable {
    var buttons: UInt64 = 0
    var dpadX: Float = 0
    var dpadY: Float = 0
    var leftX: Float = 0
    var leftY: Float = 0
    var rightX: Float = 0
    var rightY: Float = 0
    var touchX: Float = 0
    var touchY: Float = 0
    var touchActive = false

    func validated() -> InputSnapshot {
        var result = self
        result.dpadX = Self.clamp(dpadX)
        result.dpadY = Self.clamp(dpadY)
        result.leftX = Self.clamp(leftX)
        result.leftY = Self.clamp(leftY)
        result.rightX = Self.clamp(rightX)
        result.rightY = Self.clamp(rightY)
        result.touchX = Self.clamp(touchX)
        result.touchY = Self.clamp(touchY)
        return result
    }

    private static func clamp(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(1, max(-1, value))
    }
}

struct PCMBlock {
    let samples: [Int16]
    let sampleRate: Int
    let channels: Int

    var isValid: Bool {
        sampleRate > 0 && channels > 0 && samples.count % channels == 0
    }
}

enum ResourceId: String, CaseIterable {
    case bump = "IDR_BUMP"
    case cube = "IDR_CUBE"
    case glare = "IDR_GLARE"
    case para = "IDR_PARA"
    case sprite = "IDR_SPRITE"
    case toon = "IDR_TOON"
    case water = "IDR_WATER"
}

protocol ResourceStore {
    func data(for resource: ResourceId) throws -> Data
}

struct BundleResourceStore: ResourceStore {
    let bundle: Bundle

    func data(for resource: ResourceId) throws -> Data {
        guard let url = bundle.url(forResource: resource.rawValue, withExtension: "bin") else {
            throw NSError(domain: "PortRuntime.ResourceStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "缺少资源：\(resource.rawValue)"])
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}

protocol PortRuntimeHost: AnyObject {
    var paths: GamePaths { get }
    var input: InputSnapshot { get }
    var isActive: Bool { get }
    func submitAudio(_ block: PCMBlock) -> Bool
    func record(_ message: String)
}

final class DefaultPortRuntimeHost: PortRuntimeHost {
    let paths: GamePaths
    private(set) var input = InputSnapshot()
    private(set) var isActive = true

    init() throws {
        paths = try GamePaths()
    }

    func update(input: InputSnapshot) {
        self.input = input.validated()
    }

    func setActive(_ active: Bool) {
        isActive = active
        record(active ? "运行时恢复前台" : "运行时暂停后台")
    }

    func submitAudio(_ block: PCMBlock) -> Bool {
        guard isActive, block.isValid else {
            record("拒绝无效或非活动音频块")
            return false
        }
        record("PCM 输出后端尚未接入")
        return false
    }

    func record(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        do {
            let handle = try FileHandle(forWritingTo: paths.logs)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // Logging must never crash the guest runtime.
        }
    }
}
