import Foundation
import Network
import OmiImportCore

/// Gets finished recordings to the Mac: finds it on the network, sends each
/// one, and deletes the phone's copy once the Mac says it is stored.
///
/// What is waiting is simply every recording whose audio is still on the
/// phone, so there is no list to get out of step.
final class Outbox {
    private let queue = DispatchQueue(label: "com.mathetic.OmiRelay.outbox")
    private weak var relay: Relay?
    private let layout: RecordingLayout
    private var browser: NWBrowser?
    private var macs: [NWEndpoint] = []
    private var code: String?
    private var address = ""
    private var sending = false
    private var lastTry = Date.distantPast
    private var networkDenied = false

    init(relay: Relay, layout: RecordingLayout) {
        self.relay = relay
        self.layout = layout
    }

    /// The pairing code, and an address to try when the Mac isn't on this
    /// network (its name on a VPN, say). Starts looking for the Mac.
    func configure(code: String?, address: String) {
        queue.async {
            self.code = code
            self.address = address.trimmingCharacters(in: .whitespaces)
            self.browser?.cancel()
            self.browser = nil
            self.macs = []
            guard code != nil else { return }
            self.browse()
            self.send()
        }
    }

    /// Try now: a recording was just finished, or the person asked.
    func kick() {
        queue.async { self.send() }
    }

    /// Called about once a minute while the app is awake.
    func tick() {
        queue.async {
            if Date().timeIntervalSince(self.lastTry) >= 60 { self.send() }
        }
    }

    private func browse() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Handoff.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .waiting(let error):
                // iOS says this when Local Network access was turned down.
                if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                    self.networkDenied = true
                    self.report()
                }
            case .failed:
                self.browser = nil
                self.queue.asyncAfter(deadline: .now() + 10) { if self.browser == nil, self.code != nil { self.browse() } }
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.networkDenied = false
            self.macs = results.map(\.endpoint)
            if !self.macs.isEmpty { self.send() } else { self.report() }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private var typedEndpoint: NWEndpoint? {
        guard !address.isEmpty else { return nil }
        var host = address, port = Handoff.port
        if let colon = address.lastIndex(of: ":"), let typed = UInt16(address[address.index(after: colon)...]) {
            host = String(address[..<colon])
            port = typed
        }
        return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
    }

    private func waiting() -> [Recording] {
        Ledger.load(from: layout.ledgerURL).recordings
            .filter { FileManager.default.fileExists(atPath: layout.folder.appendingPathComponent($0.file).path) }
            .sorted { $0.start < $1.start }
    }

    private func send() {
        guard !sending, let code else { return }
        let waiting = waiting()
        let endpoints = macs + [typedEndpoint].compactMap { $0 }
        guard !waiting.isEmpty, !endpoints.isEmpty else {
            report(waiting: waiting.count)
            return
        }
        sending = true
        lastTry = Date()
        status("Sending \(waiting.count) to your Mac")
        let folder = layout.folder
        Task {
            var failure: Error?
            for endpoint in endpoints {
                do {
                    let items = try waiting.map { try HandoffClient.Item($0, in: folder) }
                    try await HandoffClient.send(items, to: endpoint, code: code) { item, file in
                        // The Mac has it: the phone's copy can go.
                        try? FileManager.default.removeItem(at: item.url)
                        try? FileManager.default.removeItem(at: item.url.deletingPathExtension().appendingPathExtension("md"))
                        Log.write("sent \(item.url.lastPathComponent): the Mac has it as \(file)")
                        DispatchQueue.main.async { self.relay?.reload() }
                    }
                    failure = nil
                    break
                } catch {
                    Log.write("could not send to \(endpoint): \(error)")
                    failure = error
                }
            }
            let outcome = failure
            self.queue.async {
                self.sending = false
                self.report(failure: outcome)
            }
        }
    }

    private func report(waiting count: Int? = nil, failure: Error? = nil) {
        let count = count ?? waiting().count
        let left = count == 0 ? "" : " \(count) waiting."
        switch failure {
        case HandoffError.wrongCode?:
            status("Your Mac has a different pairing code. Type the one it shows now.", problem: true)
        case HandoffError.refused(let why)?:
            status("\(why)\(left)", problem: true)
        case .some:
            status("Couldn't reach your Mac.\(left)")
        case nil where networkDenied:
            status("Allow Omi Relay to find your Mac: Settings › Privacy & Security › Local Network.", problem: true)
        case nil where count == 0:
            status("Everything is on your Mac.")
        case nil:
            status(macs.isEmpty && typedEndpoint == nil ? "Looking for your Mac.\(left)" : "\(count) waiting for your Mac.")
        }
    }

    private func status(_ text: String, problem: Bool = false) {
        DispatchQueue.main.async { self.relay?.setMacStatus(text, problem: problem) }
    }
}
