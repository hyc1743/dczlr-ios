// Self-authored diagnostic entry point for the actual interpreter frontend.
import Foundation

@MainActor
extension AppModel {
    func launchPortLabRuntimeCheck() {
        guard let rootFilesystem else {
            alertMessage = "Import the Wine runtime ZIP in Settings before running this check."
            return
        }
        guard let prefixes = Storage.winePrefixes,
              let documents = Storage.documents,
              let source = Bundle.main.url(forResource: "portlab-win32-smoke", withExtension: "exe") else {
            alertMessage = "The bundled compatibility check or its storage directory is unavailable."
            return
        }
        // This folder and prefix belong only to the self-authored check.
        let directory = documents.appendingPathComponent("RuntimeChecks", isDirectory: true)
        let target = directory.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)
            Log.write("Starting self-authored PE32 check: files, threads, offscreen GDI and silent PCM. "
                      + "Look for PORTLAB_WIN32_OK in guest output. This does not test D3D9 or audible output.",
                      category: "runtime-check")
            try Session.launch(
                rootFilesystem: rootFilesystem,
                writableRoot: prefixes.appendingPathComponent("portlab-runtime-check"),
                gameDirectory: directory,
                sharedDirectory: nil,
                executablePath: "d:\\portlab-win32-smoke.exe",
                arguments: [],
                environment: ["WINEDEBUG=err+all,warn+all,+seh",
                              "WINEDLLOVERRIDES=mscoree,mshtml=;winemenubuilder.exe=d"],
                workingDirectory: "/mnt/game",
                width: 800, height: 600,
                soundEnabled: true,
                runThroughWine: true)
        } catch {
            alertMessage = "The compatibility check could not start: " + error.localizedDescription
        }
    }
}
