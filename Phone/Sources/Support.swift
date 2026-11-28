import Foundation
import Security

enum Paths {
    /// The app's own folder. Nothing in it is an archive: recordings wait
    /// here only until the Mac has them.
    static let home: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let home = support.appendingPathComponent("OmiRelay", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }()

    static var recordings: URL { home.appendingPathComponent("Recordings", isDirectory: true) }
    static var log: URL { home.appendingPathComponent("omi-relay.log") }
}

/// A plain text log of what the pendant said and what was done about it.
/// The app can share it, which is how a first run on a real pendant is read.
enum Log {
    private static let queue = DispatchQueue(label: "com.mathetic.OmiRelay.log")
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

/// The pairing code, kept in the keychain and nowhere else.
enum PairingCode {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.mathetic.OmiRelay.mac",
        kSecAttrAccount as String: "pairing-code",
    ]

    static var value: String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ code: String) -> Bool {
        remove()
        var item = query
        item[kSecValueData as String] = Data(code.utf8)
        // Readable while the phone is locked, which is when most sending happens.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove() {
        SecItemDelete(query as CFDictionary)
    }
}

func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
