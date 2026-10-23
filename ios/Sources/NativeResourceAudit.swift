import Foundation

enum NativeResourceAudit {
    static func inspect(dataDirectory: URL) throws -> String {
        let files = try FileManager.default.contentsOfDirectory(
            at: dataDirectory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { $0.pathExtension.lowercased() == "pp" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            return "尚未找到 game/Data 中的 PP 资源包。请先完成资源导入。"
        }
        var recognized = 0
        var entries: UInt64 = 0
        var sampleBytes = 0
        var unsupported: [String] = []
        for file in files {
            do {
                let archive = try DCArchive(url: file)
                // A bounded sample exercises the actual native read/decode path.
                if archive.entryCount > 0 {
                    let first = try archive.readPrefix(at: 0, length: 64)
                    sampleBytes += first.count
                }
                recognized += 1
                entries += UInt64(archive.entryCount)
            } catch {
                unsupported.append(file.lastPathComponent)
            }
        }
        let unknown = unsupported.isEmpty ? "无未识别文件" : "未通过：" + unsupported.joined(separator: ", ")
        return "原生资源检查：\(recognized)/\(files.count) 包，\(entries) 条目，读取 \(sampleBytes) 字节。\(unknown)。此结果不代表游戏已启动。"
    }
}
