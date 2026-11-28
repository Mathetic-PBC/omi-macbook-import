import Foundation
import Security

enum Paths {
    /// The app's own settings and log. OMI_IMPORT_HOME moves them, which is
    /// how a test run keeps away from the real ones.
    static let home: URL = {
        if let override = ProcessInfo.processInfo.environment["OMI_IMPORT_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("OmiImport", isDirectory: true)
    }()

    static let isOverridden = ProcessInfo.processInfo.environment["OMI_IMPORT_HOME"]?.isEmpty == false

    static var settings: URL { home.appendingPathComponent("settings.json") }
    static var log: URL { home.appendingPathComponent("omi-import.log") }
}

/// A plain text log of what arrived and what was done about it.
enum Log {
    private static let queue = DispatchQueue(label: "com.mathetic.OmiImport.log")
    private static let limit = 1024 * 1024
    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        #if DEBUG
        FileHandle.standardError.write(Data(line.utf8))
        #endif
        queue.async {
            let url = Paths.log
            let manager = FileManager.default
            try? manager.createDirectory(at: Paths.home, withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit {
                try? manager.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// Something kept in the login keychain and nowhere else.
struct Secret {
    let service: String
    let account: String
    /// A debug build never touches the keychain: its value comes from this
    /// environment variable, for a test run.
    let debugVariable: String

    #if DEBUG
    var value: String? { ProcessInfo.processInfo.environment[debugVariable] }
    func save(_ value: String) -> Bool { false }
    func remove() {}
    #else
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    var value: String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String) -> Bool {
        remove()
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func remove() {
        SecItemDelete(query as CFDictionary)
    }
    #endif
}

/// What the person chose in setup.
struct Settings: Codable, Equatable {
    enum EngelbartChoice: String, Codable { case undecided, yes, no }

    /// The import folder.
    var destination: String?
    var engelbart: EngelbartChoice = .undecided
    /// The folder Engelbart's library row was made for, and the row.
    var engelbartFolder: String?
    var engelbartRowID: String?
    /// When something last arrived, from the phone or the cloud.
    var lastImport: Date?

    var destinationURL: URL? { destination.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var inEngelbart: Bool { engelbartRowID != nil && engelbartFolder == destination }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: Paths.settings) else { return Settings() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Settings.self, from: data)) ?? Settings()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
            try encoder.encode(self).write(to: Paths.settings, options: .atomic)
        } catch {
            Log.write("settings: could not save: \(error)")
        }
    }
}

func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
