import XCTest
@testable import OmiImportCore

final class AssembleTests: XCTestCase {
    var folder: URL!
    var layout: RecordingLayout!
    var frames: [Data] = []
    let t0: UInt32 = 1_795_000_000 // 2026-11-18 11:06:40 UTC

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("omi-assemble-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        layout = RecordingLayout(folder: folder, timeZone: TimeZone(identifier: "UTC")!)
        let url = try XCTUnwrap(Bundle.module.url(forResource: "voice-20ms", withExtension: "opus", subdirectory: "Fixtures"))
        frames = Array(try readOgg(try Data(contentsOf: url)).packets.dropFirst(2))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func journal(_ key: String) -> RecordJournal { RecordJournal(folder: layout.stateFolder, key: key) }

    func records(_ data: [Data], from seq: UInt64 = 0) -> [PendantRecord] {
        data.enumerated().map { PendantRecord(seq: seq + UInt64($0.offset), bytes: $0.element) }
    }

    func date(_ seconds: UInt32) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }

    func audioFrames(_ recording: Recording) throws -> [Data] {
        Array(try readOgg(try Data(contentsOf: folder.appendingPathComponent(recording.file))).packets.dropFirst(2))
    }

    // MARK: Recordings

    /// Two conversations with a pause between them become two recordings,
    /// each an .opus holding exactly the pendant's frames and a note.
    func testWritesOneRecordingPerConversation() throws {
        let first = RecordMaker.records(frames: frames, start: t0, seconds: 20)
        let second = RecordMaker.records(frames: frames, start: t0 + 600, seconds: 8)
        let ring = journal("ring-a")
        try ring.append(records(first + second))

        let written = try Assembler(layout: layout).run(device: "Omi", firmware: "3.0.24", now: date(t0 + 3600))
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(written.map(\.file), ["2026-11-18/2026-11-18 11-06-39.opus", "2026-11-18/2026-11-18 11-16-39.opus"])
        XCTAssertEqual(written[0].seconds, 20, accuracy: 0.5)
        XCTAssertEqual(written[1].seconds, 8, accuracy: 0.5)

        XCTAssertEqual(try audioFrames(written[0]), records(first).flatMap(\.frames))
        XCTAssertEqual(try audioFrames(written[1]), records(second).flatMap(\.frames))

        let note = try String(contentsOf: folder.appendingPathComponent("2026-11-18/2026-11-18 11-06-39.md"), encoding: .utf8)
        XCTAssertTrue(note.hasPrefix("# Omi · Wednesday 18 November 2026, 11:06\n"), note)
        XCTAssertTrue(note.contains("- Started: 2026-11-18 11:06:39 +00:00"), note)
        XCTAssertTrue(note.contains("- Length: 20 s"), note)
        XCTAssertTrue(note.contains("- Audio: [2026-11-18 11-06-39.opus](2026-11-18%2011-06-39.opus)"), note)
        XCTAssertTrue(note.contains("- Pendant: Omi, firmware 3.0.24"), note)
        XCTAssertFalse(note.contains("Clock"), note)

        // The journal is empty, the ledger has both, nothing is left in incoming.
        XCTAssertTrue(ring.load().isEmpty)
        XCTAssertEqual(Ledger.load(from: layout.ledgerURL).recordings.map(\.file), written.map(\.file))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: layout.incomingFolder.path), [])
    }

    /// A conversation still going on isn't written until it has been quiet
    /// for a minute, and what arrives meanwhile joins it.
    func testAConversationInProgressWaits() throws {
        let all = RecordMaker.records(frames: frames, start: t0, seconds: 40)
        let half = all.count / 2
        let ring = journal("ring-a")
        try ring.append(records(Array(all[..<half])))

        let assembler = Assembler(layout: layout)
        XCTAssertEqual(try assembler.run(device: "Omi", firmware: nil, now: date(t0 + 25)).count, 0)
        XCTAssertEqual(ring.load().count, half)

        try ring.append(records(Array(all[half...]), from: UInt64(half)))
        XCTAssertEqual(try assembler.run(device: "Omi", firmware: nil, now: date(t0 + 45)).count, 0)

        let written = try assembler.run(device: "Omi", firmware: nil, now: date(t0 + 40 + 61))
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(try audioFrames(written[0]), records(all).flatMap(\.frames))
    }

    /// Running again writes nothing twice, even if the journal wasn't
    /// emptied (the app stopped between writing a recording and tidying up).
    func testNothingIsWrittenTwice() throws {
        let data = RecordMaker.records(frames: frames, start: t0, seconds: 5)
        let ring = journal("ring-a")
        try ring.append(records(data))
        let assembler = Assembler(layout: layout)
        XCTAssertEqual(try assembler.run(device: "Omi", firmware: nil, now: date(t0 + 500)).count, 1)

        // The same records turn up in the journal again.
        try ring.append(records(data))
        XCTAssertEqual(try assembler.run(device: "Omi", firmware: nil, now: date(t0 + 900)).count, 0)
        XCTAssertTrue(ring.load().isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("2026-11-18").path)
        XCTAssertEqual(files.sorted(), ["2026-11-18 11-06-39.md", "2026-11-18 11-06-39.opus"])
    }

    /// Audio stored on the pendant up to the moment it connected, and audio
    /// heard live from then on, are one recording.
    func testStoredAndLiveAudioJoin() throws {
        let stored = RecordMaker.records(frames: frames, start: t0, seconds: 10)
        let live = RecordMaker.records(frames: frames, start: t0 + 12, seconds: 10)
        let later = RecordMaker.records(frames: frames, start: t0 + 400, seconds: 3)
        try journal("ring-a").append(records(stored))
        try journal("live-a").append(records(live + later))

        let written = try Assembler(layout: layout).run(device: "Omi", firmware: "3.0.21", now: date(t0 + 4000))
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(try audioFrames(written[0]), records(stored).flatMap(\.frames) + records(live).flatMap(\.frames))
        XCTAssertEqual(written[0].spans?.map(\.journal), ["ring-a", "live-a"])
        XCTAssertEqual(try audioFrames(written[1]), records(later).flatMap(\.frames))
    }

    /// The Mac connects in the middle of a conversation and lets go again
    /// before it ends: stored, then live, then stored, in the order spoken.
    func testLiveAudioInTheMiddleOfStored() throws {
        let before = RecordMaker.records(frames: frames, start: t0, seconds: 10)
        let live = RecordMaker.records(frames: frames, start: t0 + 12, seconds: 20)
        let after = RecordMaker.records(frames: frames, start: t0 + 34, seconds: 10)
        // The ring's records run on from one another; the live ones sit in the gap.
        try journal("ring-a").append(records(before + after))
        try journal("live-a").append(records(live))

        let written = try Assembler(layout: layout).run(device: "Omi", firmware: "3.0.21", now: date(t0 + 4000))
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(try audioFrames(written[0]),
                       records(before).flatMap(\.frames) + records(live).flatMap(\.frames) + records(after).flatMap(\.frames))
        XCTAssertEqual(written[0].spans, [
            .init(journal: "ring-a", first: 0, last: UInt64(before.count - 1)),
            .init(journal: "live-a", first: 0, last: UInt64(live.count - 1)),
            .init(journal: "ring-a", first: UInt64(before.count), last: UInt64(before.count + after.count - 1)),
        ])
        XCTAssertEqual(written[0].seconds, 40, accuracy: 1)
        XCTAssertTrue(journal("ring-a").load().isEmpty)
        XCTAssertTrue(journal("live-a").load().isEmpty)
    }

    /// Two recordings that start in the same second get different names.
    func testNamesDoNotCollide() throws {
        var taken: Set<String> = []
        let names = (0..<3).map { _ -> String in
            let name = layout.baseName(for: date(t0)) { taken.contains($0) }
            taken.insert(name)
            return name
        }
        XCTAssertEqual(names, ["2026-11-18 11-06-40", "2026-11-18 11-06-40 2", "2026-11-18 11-06-40 3"])
    }

    /// A span of records never reaches over records that aren't in the
    /// recording, so those are not taken for done.
    func testSpansDoNotCoverRecordsLeftOut() {
        let data = records(RecordMaker.records(frames: frames, start: t0, seconds: 3))
        var timed = data.map { TimedRecord(journal: "ring-a", record: $0, time: $0.time) }
        timed.remove(at: 3)
        let spans = Segment(records: timed).spans
        XCTAssertEqual(spans.count, 2)
        var ledger = Ledger()
        ledger.recordings = [Recording(file: "x", start: Date(), seconds: 1, bytes: 1, device: "Omi", spans: spans)]
        XCTAssertTrue(ledger.covers(journal: "ring-a", seq: 2))
        XCTAssertFalse(ledger.covers(journal: "ring-a", seq: 3))
        XCTAssertTrue(ledger.covers(journal: "ring-a", seq: 4))
        XCTAssertFalse(ledger.covers(journal: "ring-b", seq: 2))
    }

    /// A clock that was never set: the recording is kept, with a guessed time
    /// and a note that says so.
    func testUnsetClock() throws {
        let data = RecordMaker.records(frames: frames, start: 0x8000_0000 | 500, seconds: 4)
        try journal("ring-a").append(records(data))
        let written = try Assembler(layout: layout).run(device: "Omi", firmware: "3.0.24", closeAll: true, now: date(t0))
        XCTAssertEqual(written.count, 1)
        XCTAssertNotNil(written[0].clockNote)
        XCTAssertEqual(written[0].start.timeIntervalSince1970, Double(t0) - written[0].seconds, accuracy: 0.01)
    }

    // MARK: Clock

    /// The pendant restarted away from the Mac: what it recorded since is
    /// stamped early by the time it was off, which the Mac measures when it
    /// next connects. What it recorded before restarting is left alone.
    func testClockCorrectedAfterARestart() throws {
        let before = RecordMaker.records(frames: frames, start: t0 + 3600, seconds: 5) // stamped right
        // Off for 4 hours; restarts counting from t0 (when the Mac last set it).
        let after = RecordMaker.records(frames: frames, start: t0 + 30, seconds: 5)
        let all = records(before + after)
        let ring = journal("ring-a")
        try ring.append(all)
        // On connecting, the pendant's clock reads 4 h behind this Mac's.
        try ring.noteClock(boundary: UInt64(all.count), drift: -14_400)

        let timed = ClockCorrection.apply(all, entries: ring.clock)
        XCTAssertEqual(timed[0].correction, 0)
        XCTAssertEqual(timed[before.count].correction, 14_400)
        XCTAssertEqual(timed.last?.time, date(t0 + 35 + 14_400))

        let written = try Assembler(layout: layout).run(device: "Omi", firmware: nil, now: date(t0 + 100_000))
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(written[0].start.timeIntervalSince1970, Double(t0 + 3600), accuracy: 1)
        XCTAssertNil(written[0].clockNote)
        XCTAssertEqual(written[1].start.timeIntervalSince1970, Double(t0 + 30 + 14_400), accuracy: 1)
        XCTAssertEqual(written[1].clockNote, "The pendant's clock was 4 h 0 min behind when this was copied. The time here is corrected.")
    }

    /// No restart, the clock simply off: everything is corrected.
    func testClockCorrectedWithNoRestart() {
        let all = records(RecordMaker.records(frames: frames, start: t0, seconds: 5))
        let timed = ClockCorrection.apply(all, entries: [ClockEntry(boundary: UInt64(all.count), drift: 240, at: Date(), complete: true)])
        XCTAssertTrue(timed.allSatisfy { $0.correction == -240 })
        XCTAssertEqual(timed[0].time, all[0].time?.addingTimeInterval(-240))
        // A small difference is left alone.
        let small = ClockCorrection.apply(all, entries: [ClockEntry(boundary: UInt64(all.count), drift: 3, at: Date(), complete: true)])
        XCTAssertTrue(small.allSatisfy { $0.correction == 0 })
        // Records after the boundary were stamped by the clock the Mac set.
        let partial = ClockCorrection.apply(all, entries: [ClockEntry(boundary: 2, drift: 240, at: Date(), complete: true)])
        XCTAssertEqual(partial.map(\.correction), [-240, -240] + Array(repeating: 0, count: all.count - 2))
    }

    /// Two restarts: the stretch between them is off by an amount nobody
    /// measured, and says so.
    func testTwoRestartsMarkTheMiddle() throws {
        let a = RecordMaker.records(frames: frames, start: t0 + 5000, seconds: 3)
        let b = RecordMaker.records(frames: frames, start: t0 + 100, seconds: 3)
        let c = RecordMaker.records(frames: frames, start: t0 + 20, seconds: 3)
        let all = records(a + b + c)
        let timed = ClockCorrection.apply(all, entries: [ClockEntry(boundary: UInt64(all.count), drift: -9000, at: Date(), complete: true)])
        XCTAssertFalse(timed[0].unreliable)
        XCTAssertEqual(timed[0].correction, 0)
        XCTAssertTrue(timed[a.count].unreliable)
        XCTAssertEqual(timed[a.count].correction, 0)
        XCTAssertFalse(timed[a.count + b.count].unreliable)
        XCTAssertEqual(timed[a.count + b.count].correction, 9000)

        let ring = journal("ring-a")
        try ring.append(all)
        try ring.noteClock(boundary: UInt64(all.count), drift: -9000)
        let written = try Assembler(layout: layout).run(device: "Omi", firmware: nil, now: date(t0 + 100_000))
        XCTAssertEqual(written.count, 3)
        XCTAssertEqual(written.filter { $0.clockNote?.contains("restarted more than once") == true }.count, 1)
    }

    /// Records from before the clock was put right aren't finished until all
    /// of them are here: only then is it known where the pendant restarted.
    func testHeldUntilTheClockRangeIsComplete() throws {
        let all = RecordMaker.records(frames: frames, start: t0, seconds: 10)
        let half = all.count / 2
        let ring = journal("ring-a")
        try ring.append(records(Array(all[..<half])))
        try ring.noteClock(boundary: UInt64(all.count), drift: -600)
        XCTAssertEqual(ring.heldFrom, 0)

        let assembler = Assembler(layout: layout)
        XCTAssertEqual(try assembler.run(device: "Omi", firmware: nil, now: date(t0 + 50_000)).count, 0)

        try ring.append(records(Array(all[half...]), from: UInt64(half)))
        let written = try assembler.run(device: "Omi", firmware: nil, now: date(t0 + 50_000))
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0].start.timeIntervalSince1970, Double(t0 + 600), accuracy: 1)
        XCTAssertNil(ring.heldFrom)
    }

    /// A conversation recorded across the moment the clock was put right
    /// stays one recording.
    func testCorrectionDoesNotSplitAConversation() throws {
        let early = RecordMaker.records(frames: frames, start: t0, seconds: 5) // stamped 1000 s early
        let late = RecordMaker.records(frames: frames, start: t0 + 1005, seconds: 5) // stamped right
        let all = records(early + late)
        let ring = journal("ring-a")
        try ring.append(all)
        try ring.noteClock(boundary: UInt64(early.count), drift: -1000)
        let written = try Assembler(layout: layout).run(device: "Omi", firmware: nil, now: date(t0 + 50_000))
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0].seconds, 10, accuracy: 0.5)
    }

    // MARK: Live audio

    /// Live notifications, whole frames or split across several, become
    /// records holding the same frames in order.
    func testLivePacker() throws {
        for mtuPayload in [200, 60] {
            var packer = LivePacker()
            var made: [Data] = []
            var index: UInt16 = 0
            var now = date(t0)
            let source = (0..<150).map { frames[$0 % frames.count] }
            for frame in source {
                var offset = 0
                var fragment: UInt8 = 0
                while offset < frame.count {
                    let end = min(offset + mtuPayload, frame.count)
                    let header = Data([UInt8(index & 0xFF), UInt8(index >> 8), fragment])
                    made += packer.receive(header + frame[frame.startIndex + offset..<frame.startIndex + end], at: now)
                    index &+= 1
                    fragment += 1
                    offset = end
                }
                now = now.addingTimeInterval(0.02)
            }
            XCTAssertTrue(packer.tick(at: now.addingTimeInterval(0.5)).isEmpty, "not idle yet")
            made += packer.tick(at: now.addingTimeInterval(1.5))
            XCTAssertTrue(made.allSatisfy { $0.count == PendantRecord.size })
            let parsed = records(made)
            XCTAssertEqual(parsed.flatMap(\.frames), source, "payload \(mtuPayload)")
            XCTAssertEqual(parsed.first?.time.map { Int($0.timeIntervalSince1970) }, Int(t0))
        }
    }

    /// A whole pass, pendant to file: a simulated pendant is drained and the
    /// recording that comes out is decoded by ffmpeg, when ffmpeg is here.
    func testARecordingDecodes() throws {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipIf(ffmpeg == nil, "ffmpeg isn't installed")
        let pendant = FakePendant(modern: false)
        RecordMaker.records(frames: frames, start: t0, seconds: 15, legacyTail: true).forEach(pendant.add)
        let ring = journal("ring-a")
        let session = DrainSession(send: { pendant.write($0) }, journalFor: { _ in ring }, events: { _ in })
        pendant.deliver = { session.received($0) }
        session.start()
        let written = try Assembler(layout: layout).run(device: "Omi", firmware: "3.0.21", now: date(t0 + 500))
        XCTAssertEqual(written.count, 1)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg!)
        process.arguments = ["-hide_banner", "-v", "error", "-i", folder.appendingPathComponent(written[0].file).path, "-f", "null", "-"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let complaints = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(complaints, "", "ffmpeg complained")
    }

    // MARK: Journal

    func testJournalSurvivesAPartialWrite() throws {
        let data = RecordMaker.records(frames: frames, start: t0, seconds: 2)
        let ring = journal("ring-a")
        try ring.append(records(Array(data[..<3])))
        // A crash mid-append leaves half an entry.
        let handle = try FileHandle(forWritingTo: ring.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0xAB, count: 100))
        try handle.close()
        XCTAssertEqual(ring.load().count, 3)
        try ring.append(records(Array(data[3...]), from: 3))
        XCTAssertEqual(ring.load().map(\.bytes), data)
        XCTAssertEqual(RecordJournal.all(in: layout.stateFolder).map(\.key), ["ring-a"])
    }

    func testLengths() {
        XCTAssertEqual(RecordingLayout.length(42), "42 s")
        XCTAssertEqual(RecordingLayout.length(120), "2 min")
        XCTAssertEqual(RecordingLayout.length(125), "2 min 5 s")
        XCTAssertEqual(RecordingLayout.length(3725), "1 h 2 min")
    }
}
