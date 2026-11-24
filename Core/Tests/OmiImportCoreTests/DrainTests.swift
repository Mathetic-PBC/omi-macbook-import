import XCTest
@testable import OmiImportCore

final class DrainTests: XCTestCase {
    var folder: URL!
    var frames: [Data] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("omi-drain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = try XCTUnwrap(Bundle.module.url(forResource: "voice-20ms", withExtension: "opus", subdirectory: "Fixtures"))
        frames = Array(try readOgg(try Data(contentsOf: url)).packets.dropFirst(2))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Runs one drain session against a fake pendant, to the end.
    @discardableResult
    func drain(_ pendant: FakePendant, key: String = "ring-test", window: UInt32 = 50) -> [DrainSession.Event] {
        var events: [DrainSession.Event] = []
        let journal = RecordJournal(folder: folder, key: key)
        let session = DrainSession(window: window, send: { pendant.write($0) }, journalFor: { _ in journal }, events: { events.append($0) })
        pendant.deliver = { session.received($0) }
        session.start()
        return events
    }

    // MARK: Wire format

    func testCommandsMatchTheFirmware() {
        XCTAssertEqual([UInt8](StorageCommand.info()), [0x10])
        XCTAssertEqual([UInt8](StorageCommand.read(from: 0x0102, count: 2700)),
                       [0x11, 0, 0, 0, 0, 0, 0, 0x01, 0x02, 0, 0, 0x0A, 0x8C])
        XCTAssertEqual([UInt8](StorageCommand.advance(to: 7)), [0x12, 0, 0, 0, 0, 0, 0, 0, 7])
        XCTAssertEqual(StorageCommand.advance(ring: 1, to: 2).count, 17)
        XCTAssertEqual([UInt8](StorageCommand.advance(ring: 1, to: 2)).first, 0x15)
        XCTAssertEqual([UInt8](StorageCommand.stop()), [0x03])
    }

    func testRepliesParse() {
        // INFO from 3.0.24: 41 bytes, big-endian.
        var info: [UInt8] = [0x02]
        info += [0, 0, 0, 0, 0, 0, 0, 5] + [0, 0, 0, 0, 0, 0, 1, 0] + [0, 1, 0x86, 0xA0] + [0, 0, 0, 0, 0, 0, 0, 3] + [0x01, 0xBC]
        let legacy = StorageReply.parse(Data(info))
        XCTAssertEqual(info.count, 31)
        guard case .info(let old) = legacy else { return XCTFail("not INFO") }
        XCTAssertEqual(old.readSeq, 5)
        XCTAssertEqual(old.writeSeq, 256)
        XCTAssertEqual(old.capacity, 100_000)
        XCTAssertEqual(old.dropped, 3)
        XCTAssertEqual(old.recordSize, 444)
        XCTAssertEqual(old.unread, 251)
        XCTAssertNil(old.ringID)
        XCTAssertFalse(old.freesOnConfirmation)

        info += [0x0F, 0x01] + [0xAA, 0, 0, 0, 0, 0, 0, 0xBB]
        guard case .info(let new) = StorageReply.parse(Data(info)) else { return XCTFail("not INFO") }
        XCTAssertEqual(new.ringID, 0xAA00_0000_0000_00BB)
        XCTAssertTrue(new.freesOnConfirmation)

        XCTAssertEqual(StorageReply.parse(Data([0x01, 9])), .ack(status: 9))
        XCTAssertEqual(StorageReply.parse(Data([0x04, 0, 0, 0, 0, 0, 0, 0, 0, 9])), .done(status: 0, next: 9))
        XCTAssertEqual(StorageReply.parse(Data([0x05, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 2])), .readBegin(start: 4, count: 2))
        XCTAssertEqual(StorageReply.parse(Data([0x03, 1, 2, 3])), .data(Data([1, 2, 3])))
        // A reply cut short is not acted on.
        XCTAssertEqual(StorageReply.parse(Data([0x02, 1, 2])), .unknown(Data([0x02, 1, 2])))
    }

    func testRecordFrames() {
        let a = Data([31 << 3, 1, 2, 3]), b = Data([31 << 3, 9])
        // Padding between and after frames is skipped.
        var payload = Data([4]) + a + Data([0, 0]) + Data([2]) + b
        payload.append(Data(repeating: 0, count: 440 - payload.count))
        let record = PendantRecord(seq: 1, bytes: Data([0x65, 0x5F, 0x8A, 0x00]) + payload)
        XCTAssertEqual(record.frames, [a, b])
        XCTAssertEqual(record.time, Date(timeIntervalSince1970: 0x655F_8A00))

        // 3.0.21's tail: the length of the frame that went into the next
        // record, then stale bytes. Neither is read as audio.
        let filler = Data([31 << 3]) + Data(repeating: 5, count: 99)
        let full = [filler, filler, filler, filler]
        let legacy = PendantRecord(seq: 2, bytes: RecordMaker.record(time: 100, frames: full, dangling: 100))
        XCTAssertEqual(legacy.frames, full)
        // A frame that ends exactly on the last usable byte is audio.
        let exact = [filler, filler, filler, Data([31 << 3]) + Data(repeating: 6, count: 134)]
        XCTAssertEqual(exact.reduce(0) { $0 + 1 + $1.count }, 439)
        XCTAssertEqual(PendantRecord(seq: 2, bytes: RecordMaker.record(time: 100, frames: exact)).frames, exact)

        // A clock that wasn't set: no time.
        let uptime = PendantRecord(seq: 3, bytes: RecordMaker.record(time: 0x8000_0000 | 55, frames: [a]))
        XCTAssertNil(uptime.time)
        XCTAssertNil(PendantRecord(seq: 4, bytes: RecordMaker.record(time: 0, frames: [a])).time)
        // All zeros: no audio.
        XCTAssertTrue(PendantRecord(seq: 5, bytes: Data(repeating: 0, count: 444)).frames.isEmpty)
    }

    // MARK: Draining

    func testDrainsEverythingAndFreesIt() throws {
        let pendant = FakePendant(modern: true)
        let records = RecordMaker.records(frames: frames, start: 1_800_000_000, seconds: 30)
        records.forEach(pendant.add)
        XCTAssertGreaterThan(records.count, 120) // several windows of 50

        let events = drain(pendant)
        XCTAssertEqual(events.last, .caughtUp(copied: records.count))
        XCTAssertEqual(pendant.base, UInt64(records.count), "the pendant was told to free every record")
        XCTAssertTrue(pendant.records.isEmpty)

        let journal = RecordJournal(folder: folder, key: "ring-test")
        let saved = journal.load()
        XCTAssertEqual(saved.map(\.bytes), records)
        XCTAssertEqual(saved.map(\.seq), Array(0..<UInt64(records.count)))
        XCTAssertEqual(journal.nextSeq, UInt64(records.count))
        // Every free named the ring.
        XCTAssertTrue(pendant.commands.filter { $0.first == 0x15 }.count >= 3)
        XCTAssertFalse(pendant.commands.contains { $0.first == 0x12 })
    }

    /// Notifications don't line up with records; one byte at a time still works.
    func testNotificationBoundariesDoNotMatter() throws {
        for chunk in [1, 7, 443, 444, 445, 1000] {
            let pendant = FakePendant(modern: true)
            pendant.chunk = chunk
            let records = RecordMaker.records(frames: frames, start: 1_800_000_000, seconds: 2)
            records.forEach(pendant.add)
            let key = "ring-chunk-\(chunk)"
            drain(pendant, key: key)
            XCTAssertEqual(RecordJournal(folder: folder, key: key).load().map(\.bytes), records, "chunk \(chunk)")
        }
    }

    /// The app stopped after saving a window but before telling the pendant.
    /// The next run tells it first, and copies nothing twice.
    func testResumesAfterStoppingBeforeTheAdvance() throws {
        let pendant = FakePendant(modern: true)
        let records = RecordMaker.records(frames: frames, start: 1_800_000_000, seconds: 20)
        records.forEach(pendant.add)

        // First run: the ADVANCE for the first window is never answered, and
        // the app goes away (no timeout fires).
        pendant.ignoreAdvances = 1
        let first = drain(pendant)
        XCTAssertFalse(first.contains { if case .caughtUp = $0 { return true } else { return false } })
        XCTAssertEqual(pendant.base, 0, "nothing was freed")
        let journal = RecordJournal(folder: folder, key: "ring-test")
        XCTAssertEqual(journal.load().count, 50)

        // Second run.
        pendant.commands = []
        let second = drain(pendant)
        XCTAssertEqual(second.last, .caughtUp(copied: records.count - 50))
        XCTAssertEqual(pendant.commands[1].first, 0x15, "the saved window is confirmed before anything is read")
        XCTAssertEqual(journal.load().map(\.bytes), records)
        XCTAssertTrue(pendant.records.isEmpty)
    }

    /// A lost notification leaves the records after it out of step. On
    /// firmware that waits for confirmation the window is read again.
    func testALostNotificationIsReadAgain() throws {
        let pendant = FakePendant(modern: true)
        let records = RecordMaker.records(frames: frames, start: 1_800_000_000, seconds: 5)
        records.forEach(pendant.add)
        pendant.loseOneNotification = true
        let events = drain(pendant)
        XCTAssertEqual(events.last, .caughtUp(copied: records.count))
        XCTAssertEqual(RecordJournal(folder: folder, key: "ring-test").load().map(\.bytes), records)
    }

    /// The connection drops mid-window: what arrived whole is kept, and the
    /// next run carries on. On 3.0.24 nothing is lost.
    func testConnectionLostMidWindow() throws {
        let pendant = FakePendant(modern: true)
        let records = RecordMaker.records(frames: frames, start: 1_800_000_000, seconds: 10)
        records.forEach(pendant.add)
        pendant.dropAfterData = 20

        let journal = RecordJournal(folder: folder, key: "ring-test")
        let session = DrainSession(window: 50, send: { pendant.write($0) }, journalFor: { _ in journal }, events: { _ in })
        pendant.deliver = { session.received($0) }
        session.start()
        session.connectionLost()
        let partial = journal.load().count
        XCTAssertGreaterThan(partial, 0)
        XCTAssertLessThan(partial, 50)
        XCTAssertEqual(pendant.base, 0)

        pendant.dropAfterData = nil
        let events = drain(pendant)
        XCTAssertNotNil(events.last)
        XCTAssertEqual(journal.load().map(\.bytes), records)
        XCTAssertTrue(pendant.records.isEmpty)
    }

    /// A pendant that goes quiet mid-window: the timeout keeps what arrived
    /// and asks again from there.
    func testTimeoutMidWindowCarriesOn() throws {
        let pendant = FakePendant(modern: true)
        let records = RecordMaker.records(frames: frames, start: 1_800_000_000, seconds: 6)
        records.forEach(pendant.add)
        pendant.dropAfterData = 10
        var events: [DrainSession.Event] = []
        let journal = RecordJournal(folder: folder, key: "ring-test")
        let session = DrainSession(window: 50, send: { pendant.write($0) }, journalFor: { _ in journal }, events: { events.append($0) })
        pendant.deliver = { session.received($0) }
        session.start()
        XCTAssertEqual(session.patience, 15)
        pendant.dropAfterData = nil
        session.timedOut()
        XCTAssertEqual(journal.load().map(\.bytes), records)
        if case .caughtUp = events.last {} else { XCTFail("did not finish: \(String(describing: events.last))") }
    }

    /// Firmware 3.0.21: no ring id, the plain ADVANCE, and the pendant frees
    /// records itself.
    func testLegacyFirmware() throws {
        let pendant = FakePendant(modern: false)
        let records = RecordMaker.records(frames: frames, start: 1_800_000_000, seconds: 12, legacyTail: true)
        records.forEach(pendant.add)
        let events = drain(pendant)
        XCTAssertEqual(events.last, .caughtUp(copied: records.count))
        guard case .info(let info) = events.first else { return XCTFail("no INFO") }
        XCTAssertNil(info.ringID)
        XCTAssertEqual(RecordJournal(folder: folder, key: "ring-test").load().map(\.bytes), records)
        XCTAssertTrue(pendant.commands.contains { $0.first == 0x12 })
        XCTAssertFalse(pendant.commands.contains { $0.first == 0x15 })
    }

    func testNothingStored() {
        let pendant = FakePendant(modern: true)
        XCTAssertEqual(drain(pendant).last, .caughtUp(copied: 0))
        XCTAssertEqual(pendant.commands.map { $0.first }, [0x10])
    }

    /// Records with no audio are freed but not kept.
    func testSilentRecordsAreNotKept() throws {
        let pendant = FakePendant(modern: true)
        pendant.add(Data(repeating: 0, count: 444))
        RecordMaker.records(frames: frames, start: 1_800_000_000, seconds: 1).forEach(pendant.add)
        pendant.add(Data(repeating: 0, count: 444))
        let total = pendant.records.count
        drain(pendant)
        let journal = RecordJournal(folder: folder, key: "ring-test")
        XCTAssertEqual(journal.load().count, total - 2)
        XCTAssertEqual(journal.nextSeq, UInt64(total))
        XCTAssertTrue(pendant.records.isEmpty)
    }
}
