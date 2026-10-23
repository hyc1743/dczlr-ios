import Foundation
import CryptoKit

struct DczlrPackManifest: Decodable {
    let schema: Int
    let format: String
    let game: String
    let partBytes: Int
    let totalBytes: Int64
    let fileCount: Int
    let parts: [Part]
    let files: [FileRecord]

    struct Part: Decodable { let name: String; let size: Int64; let sha256: String? }
    struct FileRecord: Decodable { let path: String; let size: Int64; let sha256: String; let segments: [Segment] }
    struct Segment: Decodable { let part: Int; let offset: Int64; let length: Int64 }

    enum CodingKeys: String, CodingKey {
        case schema, format, game, parts, files
        case partBytes = "part_bytes"
        case totalBytes = "total_bytes"
        case fileCount = "file_count"
    }

    func validate() throws {
        guard schema == 1, format == "dczlr-resource-parts-v1", game == "dczlr",
              partBytes > 0, partBytes <= 1_000_000_000,
              fileCount == files.count, !parts.isEmpty else { throw PackImportError.invalidManifest }
        guard parts.allSatisfy({ $0.name.range(of: #"^DczlrData\.part[0-9]{3}\.dczdata$"#, options: .regularExpression) != nil && $0.size > 0 }) else { throw PackImportError.invalidManifest }
        for (index, part) in parts.enumerated() {
            guard part.name == String(format: "DczlrData.part%03d.dczdata", index + 1), part.size <= Int64(partBytes), part.sha256?.count == 64 else { throw PackImportError.invalidManifest }
        }
        var partIndex = 0
        var partOffset: Int64 = 0
        var coveredTotal: Int64 = 0
        var previousPath = ""
        for record in files {
            guard record.path.hasPrefix("Data/"), record.path > previousPath,
                  !record.path.contains("\\"), !record.path.contains("\0"),
                  !record.path.contains("../") else { throw PackImportError.invalidManifest }
            previousPath = record.path
            var covered: Int64 = 0
            for segment in record.segments {
                guard segment.part == partIndex, segment.offset == partOffset,
                      segment.length > 0, segment.part < parts.count,
                      segment.offset + segment.length <= parts[segment.part].size else {
                    throw PackImportError.invalidManifest
                }
                covered += segment.length
                coveredTotal += segment.length
                partOffset += segment.length
                if partOffset == parts[partIndex].size { partIndex += 1; partOffset = 0 }
            }
            guard covered == record.size else { throw PackImportError.invalidManifest }
        }
        guard coveredTotal == totalBytes, partIndex == parts.count, partOffset == 0 else {
            throw PackImportError.invalidManifest
        }
    }
}

enum PackImportError: Error { case invalidManifest; case missingPart(String); case hashMismatch(String); case unsafePath(String); case io(String) }

final class ResourcePackImporter {
    typealias Progress = (_ completed: Int64, _ total: Int64) -> Void
    private let fileManager = FileManager.default
    private let chunkSize = 4 * 1024 * 1024

    func importPacks(from root: URL, manifestURL: URL, destination: URL, progress: Progress? = nil) throws {
        let manifest: DczlrPackManifest
        do { manifest = try JSONDecoder().decode(DczlrPackManifest.self, from: Data(contentsOf: manifestURL)); try manifest.validate() }
        catch { throw PackImportError.invalidManifest }
        let packs = root.appendingPathComponent("ResourcePacks", isDirectory: true)
        var handles: [FileHandle] = []
        defer { handles.forEach { try? $0.close() } }
        for part in manifest.parts {
            let url = fileManager.fileExists(atPath: root.appendingPathComponent(part.name).path) ? root.appendingPathComponent(part.name) : packs.appendingPathComponent(part.name)
            guard fileManager.fileExists(atPath: url.path) else { throw PackImportError.missingPart(part.name) }
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == part.size else { throw PackImportError.hashMismatch(part.name) }
            let partHash = try SHA256Stream.hash(file: url, chunkSize: chunkSize)
            guard partHash == part.sha256 else { throw PackImportError.hashMismatch(part.name) }
            handles.append(try FileHandle(forReadingFrom: url))
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var completed: Int64 = 0
        for record in manifest.files {
            guard record.path.hasPrefix("Data/"), !record.path.contains("\\"), !record.path.contains("\0"), !record.path.contains("../") else { throw PackImportError.unsafePath(record.path) }
            let relative = String(record.path.dropFirst(5))
            let target = destination.appendingPathComponent(relative)
            let base = destination.standardizedFileURL.path
            guard target.standardizedFileURL.path.hasPrefix(base + "/") else { throw PackImportError.unsafePath(record.path) }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Once gameplay can write here, packaged defaults must not replace
            // existing saves or settings, even when they differ from the manifest.
            let lower = relative.lowercased()
            if fileManager.fileExists(atPath: target.path),
               (lower.hasPrefix("save/") || lower.hasPrefix("saves/") ||
                lower.hasSuffix(".sav") || lower.hasSuffix(".cfg")) {
                completed += record.size
                progress?(completed, manifest.totalBytes)
                continue
            }
            if fileManager.fileExists(atPath: target.path),
               (try? SHA256Stream.hash(file: target, chunkSize: chunkSize)) == record.sha256,
               (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == record.size {
                completed += record.size
                progress?(completed, manifest.totalBytes)
                continue
            }
            let temporary = target.appendingPathExtension("partial")
            if fileManager.fileExists(atPath: temporary.path) { try fileManager.removeItem(at: temporary) }
            guard fileManager.createFile(atPath: temporary.path, contents: nil) else { throw PackImportError.io("无法创建临时文件") }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            var hash = SHA256Stream()
            var written: Int64 = 0
            for segment in record.segments {
                guard segment.part >= 0, segment.part < handles.count, segment.length > 0 else { throw PackImportError.invalidManifest }
                try handles[segment.part].seek(toOffset: UInt64(segment.offset)); var remaining = segment.length
                while remaining > 0 { let data = try handles[segment.part].read(upToCount: min(chunkSize, Int(remaining))) ?? Data(); guard !data.isEmpty else { throw PackImportError.hashMismatch(record.path) }; try output.write(contentsOf: data); hash.update(data); remaining -= Int64(data.count); written += Int64(data.count); completed += Int64(data.count); progress?(completed, manifest.totalBytes) }
            }
            guard written == record.size, hash.finalHex() == record.sha256 else { throw PackImportError.hashMismatch(record.path) }
            try output.close()
            if fileManager.fileExists(atPath: target.path) { try fileManager.replaceItemAt(target, withItemAt: temporary) }
            else { try fileManager.moveItem(at: temporary, to: target) }
        }
    }
}

private struct SHA256Stream {
    private var hasher = SHA256()
    mutating func update(_ value: Data) { hasher.update(data: value) }
    mutating func finalHex() -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }

    static func hash(file: URL, chunkSize: Int) throws -> String {
        var stream = SHA256Stream(); let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty { stream.update(data) }
        return stream.finalHex()
    }
}
