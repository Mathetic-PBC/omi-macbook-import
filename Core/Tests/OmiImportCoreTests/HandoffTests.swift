import Network
import XCTest
@testable import OmiImportCore

/// A phone handing recordings to a Mac, over a real connection on this machine.
final class HandoffTests: XCTestCase {
    var mac: URL!
    var phone: URL!
    var layout: RecordingLayout!
    var server: HandoffServer?
    let code = "0123456789ABCDEFGHJK"
    let start = Date(timeIntervalSince1970: 1_795_000_000.25) // 2026-11-18 11:06:40 UTC

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-handoff-\(UUID().uuidString)")
        mac = root.appendingPathComponent("mac")
        phone = root.appendingPathComponent("phone")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: phone, withIntermediateDirectories: true)
        layout = RecordingLayout(folder: mac, timeZone: TimeZone(identifier: "UTC")!)
    }

    override func tearDownWithError() throws {
        server?.stop()
        try? FileManager.default.removeItem(at: mac.deletingLastPathComponent())
    }

    /// Starts the Mac's side on a free port, off Bonjour, and gives where to reach it.
    func listen(code: String? = nil, events: @escaping (HandoffServer.Event) -> Void = { _ in }) async throws -> NWEndpoint {
        let ready = expectation(description: "listening")
        var port: UInt16 = 0
        let server = HandoffServer(layout: layout, code: code ?? self.code, port: 0, advertise: false) { event in
            if case .ready(let found) = event {
                port = found
                ready.fulfill()
            }
            events(event)
        }
        try server.start()
        self.server = server
        await fulfillment(of: [ready], timeout: 5)
        return .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    }

    /// A recording on the phone: bytes that aren't audio, which the transfer never looks at.
    func item(_ name: String, bytes: Int, at start: Date? = nil) throws -> HandoffClient.Item {
        let url = phone.appendingPathComponent(name)
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ bytes) }).write(to: url)
        let recording = Recording(file: name, start: start ?? self.start, seconds: 12.5, bytes: bytes, device: "Omi",
                                  firmware: "3.0.21", clockNote: "The time here is corrected.")
        return try HandoffClient.Item(recording, in: phone)
    }

    func testRecordingsArriveWholeWithANoteAndALedgerLine() async throws {
        let endpoint = try await listen()
        // Bigger than one chunk, and one that isn't a whole number of them.
        let items = [try item("a.opus", bytes: 700_000), try item("b.opus", bytes: 1234, at: start.addingTimeInterval(600))]
        var delivered: [String] = []
        try await HandoffClient.send(items, to: endpoint, code: code) { _, file in delivered.append(file) }

        XCTAssertEqual(delivered, ["2026-11-18/2026-11-18 11-06-40.opus", "2026-11-18/2026-11-18 11-16-40.opus"])
        for (item, file) in zip(items, delivered) {
            XCTAssertEqual(try Data(contentsOf: mac.appendingPathComponent(file)), try Data(contentsOf: item.url))
        }
        let note = try String(contentsOf: mac.appendingPathComponent("2026-11-18/2026-11-18 11-06-40.md"), encoding: .utf8)
        XCTAssertTrue(note.contains("- Length: 13 s"))
        XCTAssertTrue(note.contains("- Pendant: Omi, firmware 3.0.21"))
        XCTAssertTrue(note.contains("- Clock: The time here is corrected."))
        XCTAssertTrue(note.contains("[2026-11-18 11-06-40.opus]"))

        let ledger = Ledger.load(from: layout.ledgerURL)
        XCTAssertEqual(ledger.recordings.map(\.file), delivered)
        XCTAssertEqual(ledger.recordings.map(\.digest), items.map(\.offer.sha256))
        // The ledger keeps times to the second.
        XCTAssertEqual(ledger.recordings[0].start.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(ledger.recordings[0].bytes, 700_000)
        // Nothing half-arrived is left lying about.
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: layout.incomingFolder.path)) ?? [], [])
    }

    /// The receipt was lost and the phone sends again: the Mac says it has
    /// it, and keeps one copy.
    func testARecordingSentTwiceIsKeptOnce() async throws {
        let endpoint = try await listen()
        let items = [try item("a.opus", bytes: 5000)]
        try await HandoffClient.send(items, to: endpoint, code: code) { _, _ in }
        var again: [String] = []
        try await HandoffClient.send(items, to: endpoint, code: code) { _, file in again.append(file) }

        XCTAssertEqual(again, ["2026-11-18/2026-11-18 11-06-40.opus"])
        XCTAssertEqual(Ledger.load(from: layout.ledgerURL).recordings.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mac.appendingPathComponent("2026-11-18").path).sorted(),
                       ["2026-11-18 11-06-40.md", "2026-11-18 11-06-40.opus"])
    }

    /// Deleted on the Mac since: not asked for again.
    func testARecordingDeletedOnTheMacStaysDeleted() async throws {
        let endpoint = try await listen()
        let items = [try item("a.opus", bytes: 5000)]
        try await HandoffClient.send(items, to: endpoint, code: code) { _, _ in }
        try FileManager.default.removeItem(at: mac.appendingPathComponent("2026-11-18"))
        try await HandoffClient.send(items, to: endpoint, code: code) { _, _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: mac.appendingPathComponent("2026-11-18").path))
    }

    /// Two recordings that began in the same second both stay.
    func testTwoRecordingsInOneSecondGetTwoNames() async throws {
        let endpoint = try await listen()
        var delivered: [String] = []
        try await HandoffClient.send([try item("a.opus", bytes: 100), try item("b.opus", bytes: 101)],
                                     to: endpoint, code: code) { _, file in delivered.append(file) }
        XCTAssertEqual(delivered, ["2026-11-18/2026-11-18 11-06-40.opus", "2026-11-18/2026-11-18 11-06-40 2.opus"])
    }

    func testAPhoneWithAnotherCodeGetsNothingIn() async throws {
        var problems: [String] = []
        let endpoint = try await listen { if case .problem(let why) = $0 { problems.append(why) } }
        let items = [try item("a.opus", bytes: 5000)]
        do {
            try await HandoffClient.send(items, to: endpoint, code: "ZZZZZZZZZZZZZZZZZZZZ") { _, _ in XCTFail("delivered") }
            XCTFail("the Mac took a recording from a phone with the wrong code")
        } catch let error as HandoffError {
            XCTAssertEqual(error, .wrongCode)
        }
        XCTAssertEqual(Ledger.load(from: layout.ledgerURL).recordings.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mac.appendingPathComponent("2026-11-18").path))
    }

    /// The bytes aren't what the offer said: the Mac says no, keeps nothing,
    /// and the phone still has its copy to try again.
    func testADamagedRecordingIsTurnedAway() async throws {
        let endpoint = try await listen()
        var damaged = try item("a.opus", bytes: 5000)
        damaged.offer.sha256 = String(repeating: "0", count: 64)
        do {
            try await HandoffClient.send([damaged], to: endpoint, code: code) { _, _ in XCTFail("delivered") }
            XCTFail("a damaged recording was kept")
        } catch let error as HandoffError {
            XCTAssertEqual(error, .refused("The recording didn't arrive whole."))
        }
        XCTAssertEqual(Ledger.load(from: layout.ledgerURL).recordings.count, 0)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: layout.incomingFolder.path)) ?? [], [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.url.path))
    }

    func testNoMacThere() async throws {
        let endpoint = try await listen()
        server?.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        do {
            try await HandoffClient.send([try item("a.opus", bytes: 100)], to: endpoint, code: code) { _, _ in XCTFail("delivered") }
            XCTFail("sent to nobody")
        } catch let error as HandoffError {
            guard case .unreachable = error else { return XCTFail("\(error)") }
        }
    }

    /// Sends the voice fixture to a Mac that is already running, as the phone
    /// would. Skipped unless OMI_HANDOFF_ENDPOINT (host:port) and
    /// OMI_HANDOFF_CODE say where one is.
    func testAgainstARunningMac() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let target = environment["OMI_HANDOFF_ENDPOINT"]?.split(separator: ":"), target.count == 2,
              let port = NWEndpoint.Port(String(target[1])), let code = environment["OMI_HANDOFF_CODE"] else {
            throw XCTSkip("no running Mac named")
        }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "voice-20ms", withExtension: "opus", subdirectory: "Fixtures"))
        let url = phone.appendingPathComponent("voice.opus")
        try FileManager.default.copyItem(at: fixture, to: url)
        let recording = Recording(file: "voice.opus", start: Date().addingTimeInterval(-120), seconds: 3, bytes: 0, device: "Omi", firmware: "3.0.21")
        var delivered: [String] = []
        try await HandoffClient.send([try HandoffClient.Item(recording, in: phone)],
                                     to: .hostPort(host: NWEndpoint.Host(String(target[0])), port: port), code: code) { _, file in delivered.append(file) }
        XCTAssertEqual(delivered.count, 1)
        print("delivered: \(delivered)")
    }

    func testPairingCodes() {
        let code = Pairing.newCode()
        XCTAssertEqual(code.count, 20)
        XCTAssertNotEqual(code, Pairing.newCode())
        XCTAssertEqual(Pairing.normalize(Pairing.display(code).lowercased()), code)
        XCTAssertEqual(Pairing.display("0123456789ABCDEFGHJK"), "01234-56789-ABCDE-FGHJK")
        // Letters that read as digits are taken as the digits.
        XCTAssertEqual(Pairing.normalize("OI234 56789 abcde fghjk"), "0123456789ABCDEFGHJK")
        XCTAssertNil(Pairing.normalize("01234-56789"))
        XCTAssertNil(Pairing.normalize("01234-56789-ABCDE-FGHJ!"))
    }
}
