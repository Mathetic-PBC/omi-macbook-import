import Foundation
import OmiImportCore
import SwiftUI

/// The app's state: the pendant, the Mac, and what is passing between them.
/// Everything the screen shows comes from here.
@MainActor
final class Relay: ObservableObject {
    static let shared = Relay()

    @Published private(set) var pendantName = UserDefaults.standard.string(forKey: "pendantName")
    @Published private(set) var pendantStatus = "Starting"
    @Published private(set) var battery: Int?
    /// How far a copy off the pendant has got, 0 to 1; nil when none is under way.
    @Published private(set) var progress: Double?
    @Published private(set) var rows: [Row] = []
    @Published private(set) var paired = PairingCode.value != nil
    @Published private(set) var macStatus = "Not paired with a Mac yet"
    @Published private(set) var macProblem = false
    /// Where to try when the Mac isn't on this network.
    @Published var macAddress = UserDefaults.standard.string(forKey: "macAddress") ?? "" {
        didSet {
            UserDefaults.standard.set(macAddress, forKey: "macAddress")
            outbox?.configure(code: PairingCode.value, address: macAddress)
        }
    }

    /// One recording that passed through this phone lately.
    struct Row: Identifiable, Equatable {
        var id: String { file }
        var file: String
        var start: Date
        var seconds: Double
        var bytes: Int
        /// Still on the phone: the Mac hasn't confirmed it.
        var waiting: Bool
    }

    let layout = RecordingLayout(folder: Paths.recordings)
    private var pendant: PendantLink?
    private var outbox: Outbox?
    private var timer: Timer?
    private var isSample = false

    var waiting: [Row] { rows.filter(\.waiting) }

    func start() {
        guard pendant == nil else { return }
        reload()
        let outbox = Outbox(relay: self, layout: layout)
        self.outbox = outbox
        outbox.configure(code: PairingCode.value, address: macAddress)
        let pendant = PendantLink(relay: self, layout: layout)
        self.pendant = pendant
        pendant.start(pendant: UserDefaults.standard.string(forKey: "pendant").flatMap(UUID.init(uuidString:)))
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.outbox?.tick() }
        }
    }

    func reload() {
        guard !isSample else { return }
        let folder = layout.folder
        rows = Ledger.load(from: layout.ledgerURL).recordings.map {
            Row(file: $0.file, start: $0.start, seconds: $0.seconds, bytes: $0.bytes,
                waiting: FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.file).path))
        }.sorted { $0.start > $1.start }
    }

    // MARK: From the screen

    /// Takes the code the Mac shows. False when it isn't a whole code.
    func pair(_ typed: String) -> Bool {
        guard let code = Pairing.normalize(typed), PairingCode.save(code) else { return false }
        paired = true
        setMacStatus("Looking for your Mac.")
        outbox?.configure(code: code, address: macAddress)
        return true
    }

    func unpair() {
        PairingCode.remove()
        paired = false
        setMacStatus("Not paired with a Mac yet")
        outbox?.configure(code: nil, address: macAddress)
    }

    func forgetPendant() {
        pendant?.forget()
        UserDefaults.standard.removeObject(forKey: "pendant")
        UserDefaults.standard.removeObject(forKey: "pendantName")
        pendantName = nil
        battery = nil
    }

    /// Ask the pendant what it has, and try the Mac, now.
    func syncNow() {
        pendant?.copyNow()
        outbox?.kick()
    }

    // MARK: From the pendant and the Mac

    func setPendantStatus(_ text: String) { pendantStatus = text }
    func setProgress(_ value: Double?) { progress = value }
    func setBattery(_ level: Int) { battery = level }

    func remember(pendant identifier: UUID, name: String) {
        UserDefaults.standard.set(identifier.uuidString, forKey: "pendant")
        UserDefaults.standard.set(name, forKey: "pendantName")
        pendantName = name
    }

    /// A recording was finished: show it, and send it.
    func didWrite() {
        reload()
        outbox?.kick()
    }

    func setMacStatus(_ text: String, problem: Bool = false) {
        macStatus = text
        macProblem = problem
    }

    #if DEBUG
    /// A filled-in screen for looking at, with no pendant and no Mac.
    func loadSample() {
        let now = Date()
        isSample = true
        pendantName = "Omi"
        pendantStatus = "Connected. Listening."
        battery = 82
        paired = true
        macStatus = "2 waiting for your Mac."
        rows = [(4, 754.0, true), (31, 96.0, true), (58, 2710.0, false), (190, 18.0, false), (260, 1320.0, false)].map {
            Row(file: "\($0.0)", start: now.addingTimeInterval(-Double($0.0) * 60), seconds: $0.1, bytes: Int($0.1 * 4000), waiting: $0.2)
        }
    }
    #endif
}
