import AppKit
import Foundation
import OmiImportCore
import Security

/// The Omi developer key, kept in the login keychain and nowhere else.
enum CloudKey {
    private static let service = "com.mathetic.OmiImport.cloud"
    private static let account = "omi-developer-key"

    #if DEBUG
    /// A debug build never touches the keychain: its key comes from the
    /// environment, for a test server.
    static var value: String? { ProcessInfo.processInfo.environment["OMI_IMPORT_CLOUD_KEY"] }
    static func save(_ key: String) -> Bool { false }
    static func remove() {}
    #else
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static var value: String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) -> Bool {
        remove()
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove() {
        SecItemDelete(query as CFDictionary)
    }
    #endif
}

/// Omi's cloud: checks it for conversations the Omi app has synced, at
/// launch, when the Mac wakes, and every half hour in between, and copies
/// what is new into the import folder.
@MainActor
final class CloudLink {
    /// How often the cloud is asked. The API allows 25 transcript requests
    /// an hour; a check with nothing new is one.
    static let interval: TimeInterval = 30 * 60

    private weak var controller: ImportController?
    private var timer: Timer?
    private var running = false
    private var notBefore: Date?
    private var observer: NSObjectProtocol?

    init(controller: ImportController) {
        self.controller = controller
    }

    private var base: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["OMI_IMPORT_CLOUD_URL"], let url = URL(string: override) { return url }
        #endif
        return CloudAPI.base
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        // The Mac has been asleep: look as soon as the network is back.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self?.sync() }
        }
        sync()
    }

    /// One check, unless one is running or it is too soon after a refusal.
    func sync() {
        guard !running, let controller, let folder = controller.settings.destinationURL else { return }
        guard let key = CloudKey.value, !key.isEmpty else {
            controller.setCloudStatus(nil)
            return
        }
        if let notBefore, Date() < notBefore { return }
        running = true
        controller.setCloudStatus("Checking Omi's cloud…")
        let base = base
        let layout = RecordingLayout(folder: folder)
        Task {
            let outcome: Result<CloudSync.Summary, Error>
            do {
                let summary = try await Task.detached(priority: .utility) {
                    try await CloudSync(layout: layout).run { before, limit in
                        try await Self.fetch(CloudAPI.request(base: base, key: key, before: before, limit: limit))
                    }
                }.value
                outcome = .success(summary)
            } catch {
                outcome = .failure(error)
            }
            self.finished(outcome, layout: layout)
        }
    }

    private func finished(_ outcome: Result<CloudSync.Summary, Error>, layout: RecordingLayout) {
        running = false
        guard let controller else { return }
        controller.reloadLedger()
        let count = CloudState.load(from: layout.cloudStateURL).items.count
        let copied = "\(count) conversation\(count == 1 ? "" : "s") copied"
        func later(_ seconds: TimeInterval) -> String {
            notBefore = Date().addingTimeInterval(seconds)
            return notBefore!.formatted(date: .omitted, time: .shortened)
        }
        switch outcome {
        case .success(let summary):
            notBefore = nil
            Log.write("cloud: \(summary.added) new, \(summary.updated) changed, \(summary.requests) requests, history \(summary.historyComplete ? "complete" : "still going")")
            if summary.historyComplete {
                controller.setCloudStatus("Up to date. \(copied).")
            } else {
                // The rest of the history comes a few pages at a time, inside the allowance.
                controller.setCloudStatus("\(copied) so far. More at \(later(10 * 60)).")
                DispatchQueue.main.asyncAfter(deadline: .now() + 10 * 60 + 1) { [weak self] in self?.sync() }
            }
        case .failure(CloudError.unauthorized):
            Log.write("cloud: key refused")
            controller.setCloudStatus("Omi didn't accept this key.", problem: true)
        case .failure(CloudError.forbidden):
            Log.write("cloud: key lacks conversations:read")
            controller.setCloudStatus("This key can't read conversations. Make one with conversations:read.", problem: true)
        case .failure(CloudError.rateLimited(let retryAfter)):
            let wait = max(60, retryAfter)
            Log.write("cloud: allowance used up, waiting \(Int(wait)) s")
            controller.setCloudStatus("\(copied). Omi's hourly limit was reached; carrying on at \(later(wait)).")
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + 1) { [weak self] in self?.sync() }
        case .failure(let error):
            Log.write("cloud: \(error)")
            controller.setCloudStatus("Couldn't reach Omi's cloud. Trying again at \(later(5 * 60)).")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5 * 60 + 1) { [weak self] in self?.sync() }
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["OMI_IMPORT_CLOUD_ONCE"] == "1" {
            print("cloud: \(outcome) | \(controller.cloudStatus ?? "")")
            exit(0)
        }
        #endif
    }

    /// The key or the folder changed, or the person asked: check now.
    func reset() {
        notBefore = nil
        sync()
    }

    private nonisolated static func fetch(_ request: URLRequest) async throws -> CloudPage {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CloudError.offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudError.offline("no reply") }
        switch http.statusCode {
        case 200:
            let truncated = http.value(forHTTPHeaderField: "X-Omi-List-Truncated")?.lowercased() == "true"
            return CloudPage(conversations: try CloudAPI.decode(data), truncated: truncated)
        case 401: throw CloudError.unauthorized
        case 403: throw CloudError.forbidden
        case 429:
            let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 1800
            throw CloudError.rateLimited(retryAfter: wait)
        default: throw CloudError.server(http.statusCode)
        }
    }
}
