import Foundation

enum GateFailure: Error { case assertion(String) }

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    let accepted = try condition()
    if !accepted { throw GateFailure.assertion(message) }
}

@main struct ResourceImportGate {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw GateFailure.assertion("fixture path required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let manager = FileManager.default
        try require(try String(contentsOf: root.appendingPathComponent(".portlab-import-fixture"), encoding: .utf8) == "self-authored-only\n", "explicit generated fixture marker")
        let manifest = root.appendingPathComponent("DczlrData.manifest.json")
        let destination = root.appendingPathComponent("restored", isDirectory: true)
        let importer = ResourcePackImporter()
        var last: Int64 = 0
        var monotonic = true
        try importer.importPacks(from: root, manifestURL: manifest, destination: destination) { completed, total in
            monotonic = monotonic && completed >= last && completed <= total
            last = completed
        }
        let source = root.appendingPathComponent("source", isDirectory: true)
        for name in ["a.bin", "save/RP_00.sav", "settings.cfg"] {
            try require(try Data(contentsOf: source.appendingPathComponent(name)) == Data(contentsOf: destination.appendingPathComponent(name)), "exact restored file " + name)
        }
        let decoded = try JSONDecoder().decode(DczlrPackManifest.self, from: Data(contentsOf: manifest))
        try require(monotonic && last == decoded.totalBytes, "bounded monotonic progress and complete count")

        let userSave = Data("user-save".utf8), userConfig = Data("user-settings".utf8)
        try userSave.write(to: destination.appendingPathComponent("save/RP_00.sav"))
        try userConfig.write(to: destination.appendingPathComponent("settings.cfg"))
        try Data("damaged".utf8).write(to: destination.appendingPathComponent("a.bin"))
        try Data("partial".utf8).write(to: destination.appendingPathComponent("a.bin.partial"))
        try importer.importPacks(from: root, manifestURL: manifest, destination: destination)
        try require(try Data(contentsOf: destination.appendingPathComponent("a.bin")) == Data(contentsOf: source.appendingPathComponent("a.bin")), "repair stale asset and partial file")
        try require(try Data(contentsOf: destination.appendingPathComponent("save/RP_00.sav")) == userSave, "preserve user save")
        try require(try Data(contentsOf: destination.appendingPathComponent("settings.cfg")) == userConfig, "preserve user configuration")

        let firstPart = root.appendingPathComponent("DczlrData.part001.dczdata")
        let good = try Data(contentsOf: firstPart)
        var bad = good; bad[0] ^= 1
        try bad.write(to: firstPart)
        var rejected = false
        do { try importer.importPacks(from: root, manifestURL: manifest, destination: root.appendingPathComponent("bad-output")) }
        catch PackImportError.hashMismatch(_) { rejected = true }
        try require(rejected && !manager.fileExists(atPath: root.appendingPathComponent("bad-output").path), "reject corrupt part before restoring files")
        try good.write(to: firstPart)

        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        var records = document["files"] as! [[String: Any]]
        records[0]["path"] = "Data/../escape.bin"; document["files"] = records
        let badManifest = root.appendingPathComponent("unsafe.json")
        try JSONSerialization.data(withJSONObject: document).write(to: badManifest)
        rejected = false
        do { try importer.importPacks(from: root, manifestURL: badManifest, destination: root.appendingPathComponent("unsafe-output")) }
        catch PackImportError.invalidManifest { rejected = true }
        try require(rejected && !manager.fileExists(atPath: root.appendingPathComponent("escape.bin").path), "reject path escape before writes")
        document = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        records = document["files"] as! [[String: Any]]
        var segments = records[0]["segments"] as! [[String: Any]]
        segments[0]["length"] = Int64.max
        records[0]["segments"] = segments; document["files"] = records
        try JSONSerialization.data(withJSONObject: document).write(to: badManifest)
        rejected = false
        do { try importer.importPacks(from: root, manifestURL: badManifest, destination: root.appendingPathComponent("overflow-output")) }
        catch PackImportError.invalidManifest { rejected = true }
        try require(rejected, "reject oversized segment without arithmetic trap")
        print("PASS: actual Swift importer three-part roundtrip, mixed locations, stale/partial recovery, save/config preservation, corruption and path rejection")
    }
}
