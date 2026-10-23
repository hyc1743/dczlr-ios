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
        var decodedImages = 0
        var imageBytes = 0
        var imageFailures: [String] = []
        var unsupported: [String] = []
        for file in files {
            do {
                let archive = try DCArchive(url: file)
                // A bounded sample exercises the actual native read/decode path.
                if archive.entryCount > 0 {
                    let first = try archive.readPrefix(at: 0, length: 64)
                    sampleBytes += first.count
                }
                // Decode one image per archive; inspect bytes without displaying assets.
                for index in 0..<archive.entryCount {
                    guard let name = archive.asciiName(at: index),
                          ["bmp", "tga", "ema"].contains((name as NSString).pathExtension.lowercased()) else { continue }
                    do {
                        let image = try archive.decodeImage(at: index, inputLimit: 8 * 1024 * 1024,
                                                            outputLimit: 16 * 1024 * 1024)
                        decodedImages += 1
                        imageBytes += image.rgba.count
                    } catch {
                        imageFailures.append(file.lastPathComponent + ":" + name)
                    }
                    break
                }
                recognized += 1
                entries += UInt64(archive.entryCount)
            } catch {
                unsupported.append(file.lastPathComponent)
            }
        }
        let unknown = unsupported.isEmpty ? "无未识别文件" : "未通过：" + unsupported.joined(separator: ", ")
        let images = imageFailures.isEmpty ? "" : "图像解码失败：" + imageFailures.joined(separator: ", ") + "。"
        return "原生资源检查：\(recognized)/\(files.count) 包，\(entries) 条目，读取 \(sampleBytes) 字节；解码 \(decodedImages) 个图像，共 \(imageBytes) 字节 RGBA。\(unknown)。\(images)此结果不代表游戏已启动。"
    }
}
