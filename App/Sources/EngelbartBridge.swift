import AppKit
import Foundation

/// Engelbart on this Mac: whether it is there, whether its library already
/// holds the import folder, and adding the folder to it.
///
/// The library is one row per thing, kept in a PGlite database (Postgres in
/// WebAssembly) at ~/.engelbart/library.pglite. A folder is one row whose
/// contents Engelbart lists live from disk, so adding the import folder once
/// is all it takes for every later recording to be in reach, with nothing
/// copied. PGlite is a single-process database: the row is written only while
/// no copy of Engelbart has the database open, with Engelbart's own PGlite.
enum Engelbart {
    static let bundleID = "dev.engelbart.desktop"

    struct Install {
        var dataRoot: URL
        var library: URL
        /// Engelbart's own PGlite package, the version that writes this database.
        var pglite: URL
        /// A program that runs the bridge script: Engelbart's binary as Node, or node.
        var runtime: URL
        var runtimeIsElectron: Bool
    }

    enum Problem: Error, LocalizedError {
        case notInstalled
        case inUse
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Engelbart isn't installed on this Mac."
            case .inUse: return "Engelbart is open. Its library can only be changed while it is closed."
            case .failed(let message): return message
            }
        }
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The data root Engelbart uses: ~/.engelbart, or ~/.engelbart/test in a
    /// developer copy with test mode on.
    static var dataRoot: URL {
        #if DEBUG
        // A test run works on a copy of the library, never the real one.
        if let override = ProcessInfo.processInfo.environment["OMI_IMPORT_ENGELBART_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        let root = home.appendingPathComponent(".engelbart", isDirectory: true)
        if let data = try? Data(contentsOf: root.appendingPathComponent("config.json")),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           config["testMode"] as? Bool == true {
            return root.appendingPathComponent("test", isDirectory: true)
        }
        return root
    }

    static func detect() -> Install? {
        let library = dataRoot.appendingPathComponent("library.pglite", isDirectory: true)
        guard FileManager.default.fileExists(atPath: library.appendingPathComponent("PG_VERSION").path) else { return nil }
        let apps = [NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                    URL(fileURLWithPath: "/Applications/Engelbart.app"),
                    home.appendingPathComponent("Applications/Engelbart.app")].compactMap { $0 }
        for app in apps {
            let pglite = app.appendingPathComponent("Contents/Resources/app.asar.unpacked/node_modules/@electric-sql/pglite")
            let binary = app.appendingPathComponent("Contents/MacOS/Engelbart")
            guard FileManager.default.fileExists(atPath: pglite.appendingPathComponent("dist/index.js").path) else { continue }
            if FileManager.default.isExecutableFile(atPath: binary.path) {
                return Install(dataRoot: dataRoot, library: library, pglite: pglite, runtime: binary, runtimeIsElectron: true)
            }
            if let node = nodeOnMac() {
                return Install(dataRoot: dataRoot, library: library, pglite: pglite, runtime: node, runtimeIsElectron: false)
            }
        }
        return nil
    }

    private static func nodeOnMac() -> URL? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// The processes that have the library open: any copy of Engelbart, the
    /// installed one or a developer's. Empty when it is safe to write.
    static func holders(of install: Install) -> [pid_t] {
        let result = Shell.run("/usr/sbin/lsof", ["-n", "-t", "+D", install.library.path])
        return result.output.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Engelbart lists a library folder only when it is inside the home folder
    /// (its folder-files.cjs). A folder elsewhere would show as missing.
    static func canList(_ folder: URL) -> Bool {
        let real = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
        return real == homePath || real.hasPrefix(homePath + "/")
    }

    enum State: Equatable {
        case present(id: String)
        case absent
    }

    /// Reads or writes the library. Refuses while any process has it open.
    static func run(_ command: String, folder: URL, name: String, install: Install) throws -> State {
        guard holders(of: install).isEmpty else { throw Problem.inUse }
        guard let script = Bundle.main.url(forResource: "engelbart-library", withExtension: "cjs") else {
            throw Problem.failed("The app is missing engelbart-library.cjs.")
        }
        var environment = ProcessInfo.processInfo.environment
        if install.runtimeIsElectron { environment["ELECTRON_RUN_AS_NODE"] = "1" }
        let result = Shell.run(install.runtime.path,
                               [script.path, install.pglite.path, install.library.path, command, folder.path, name],
                               environment: environment, timeout: 120)
        let line = result.output.split(separator: "\n").last.map(String.init) ?? ""
        guard let data = line.data(using: .utf8),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw Problem.failed("Engelbart's library could not be read: \(result.error.isEmpty ? line : result.error)")
        }
        guard reply["ok"] as? Bool == true else {
            throw Problem.failed(reply["error"] as? String ?? "Engelbart's library could not be changed.")
        }
        switch reply["state"] as? String {
        case "present", "added": return .present(id: reply["id"] as? String ?? "")
        default: return .absent
        }
    }

    /// Asks every app that has the library open to quit, and waits until none
    /// does. Returns the installed Engelbart's location if it was one of them,
    /// so it can be opened again afterwards.
    @MainActor
    static func quitHolders(of install: Install, timeout: TimeInterval = 20) async -> (released: Bool, reopen: URL?) {
        var reopen: URL?
        for pid in holders(of: install) {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            if app.bundleIdentifier == bundleID { reopen = app.bundleURL }
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if holders(of: install).isEmpty { return (true, reopen) }
        }
        return (false, reopen)
    }
}

/// Runs a program and collects what it printed.
enum Shell {
    struct Result { var status: Int32; var output: String; var error: String }

    static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval = 30) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return Result(status: -1, output: "", error: error.localizedDescription)
        }
        // Read while it runs, so a full pipe can't stall it.
        var output = Data(), errors = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { output = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errors = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        process.waitUntilExit()
        timer.cancel()
        group.wait()
        return Result(status: process.terminationStatus,
                      output: String(decoding: output, as: UTF8.self),
                      error: String(decoding: errors, as: UTF8.self))
    }
}
