import Foundation

/// Records that have left the pendant but are not yet part of a finished
/// recording. Each one is on disk (and synced) before the pendant is told it
/// may free it, so a crash, a quit or a lost connection at any moment loses
/// nothing: the next run picks up from here.
///
/// One journal per source of records: a pendant's ring, or the audio heard
/// live from it. On disk:
///
///     <key>.journal     entries of [seq u64 BE][444-byte record]
///     <key>.next        the sequence number after the last record ever saved
///     <key>.clock.json  what the pendant's clock was off by, and up to where
public final class RecordJournal {
    public let key: String
    public let url: URL
    private let nextURL: URL
    private let clockURL: URL
    private static let entrySize = 8 + PendantRecord.size

    public init(folder: URL, key: String) {
        self.key = key
        url = folder.appendingPathComponent("\(key).journal")
        nextURL = folder.appendingPathComponent("\(key).next")
        clockURL = folder.appendingPathComponent("\(key).clock.json")
    }

    /// The sequence number after the last record saved, or nil before any.
    public var nextSeq: UInt64? {
        guard let text = try? String(contentsOf: nextURL, encoding: .utf8) else { return nil }
        return UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// When a record was last saved.
    public var lastAppend: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public var isEmpty: Bool {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0) < Self.entrySize
    }

    /// Saves records and syncs them to disk before returning.
    public func append(_ records: [PendantRecord]) throws {
        guard let last = records.last else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        // A partial entry left by a crash mid-write is cut off first.
        let end = try handle.seekToEnd()
        let whole = end - end % UInt64(Self.entrySize)
        if whole != end {
            try handle.truncate(atOffset: whole)
            try handle.seek(toOffset: whole)
        }
        try handle.write(contentsOf: Self.encode(records))
        try handle.synchronize()
        try markHandled(through: last.seq)
    }

    /// Notes a sequence number as dealt with, with or without a record saved
    /// for it (records that hold no audio aren't kept).
    public func markHandled(through seq: UInt64) throws {
        if let next = nextSeq, next > seq { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(String(seq + 1).utf8).write(to: nextURL, options: .atomic)
    }

    public func load() -> [PendantRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let bytes = [UInt8](data)
        var records: [PendantRecord] = []
        var at = 0
        while at + Self.entrySize <= bytes.count {
            records.append(PendantRecord(seq: bytes.be64(at), bytes: Data(bytes[(at + 8)..<(at + Self.entrySize)])))
            at += Self.entrySize
        }
        return records
    }

    /// Keeps only the records the test passes.
    public func keep(where test: (PendantRecord) -> Bool) throws {
        let all = load()
        let kept = all.filter(test)
        guard kept.count != all.count else { return }
        try Self.encode(kept).write(to: url, options: .atomic)
    }

    private static func encode(_ records: [PendantRecord]) -> Data {
        var data = Data(capacity: records.count * entrySize)
        for record in records {
            precondition(record.bytes.count == PendantRecord.size)
            data.appendBE(record.seq)
            data.append(record.bytes)
        }
        return data
    }

    // MARK: Clock

    public var clock: [ClockEntry] {
        guard let data = try? Data(contentsOf: clockURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ClockEntry].self, from: data)) ?? []
    }

    private func saveClock(_ entries: [ClockEntry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(entries).write(to: clockURL, options: .atomic)
    }

    /// Notes that records below `boundary` were stamped by a clock that was
    /// `drift` seconds off.
    public func noteClock(boundary: UInt64, drift: Double, at: Date = Date()) throws {
        var entries = clock
        let saved = nextSeq ?? 0
        entries.append(ClockEntry(boundary: boundary, drift: drift, at: at, complete: saved >= boundary))
        try saveClock(entries)
    }

    /// Marks the clock entries whose records have all been copied, and
    /// forgets those no record in the journal needs any more.
    public func settleClock() throws {
        var entries = clock
        guard !entries.isEmpty else { return }
        let saved = nextSeq ?? 0
        let oldest = load().first?.seq ?? saved
        for index in entries.indices where saved >= entries[index].boundary { entries[index].complete = true }
        // Keep the newest entry at or below the oldest record: it is where the
        // range of the entry after it begins.
        let needed = entries.filter { $0.boundary > oldest }
        let before = entries.filter { $0.boundary <= oldest }.max { $0.boundary < $1.boundary }
        let kept = (before.map { [$0] } ?? []) + needed
        if kept != clock { try saveClock(kept) }
    }

    /// Records at or above this can't be finished yet: the clock was off
    /// when they were recorded, and until all of them are here there is no
    /// telling where the pendant restarted.
    public var heldFrom: UInt64? {
        let entries = clock.sorted { $0.boundary < $1.boundary }
        guard let index = entries.firstIndex(where: { !$0.complete }) else { return nil }
        return index == 0 ? 0 : entries[index - 1].boundary
    }

    /// Every journal in a folder.
    public static func all(in folder: URL) -> [RecordJournal] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".journal") }.sorted()
            .map { RecordJournal(folder: folder, key: String($0.dropLast(".journal".count))) }
    }
}

/// Turns journaled records into finished recordings in the import folder.
///
/// The records of every journal are put in one line by time and cut into
/// recordings at the pauses, so a conversation that was being stored on the
/// pendant when it connected carries on in the audio heard live.
public struct Assembler {
    public let layout: RecordingLayout

    public init(layout: RecordingLayout) {
        self.layout = layout
    }

    /// Writes every recording that is over: one whose last audio is more
    /// than a minute old, or all of them when `closeAll`. Returns what was
    /// written.
    @discardableResult
    public func run(device: String, firmware: String?, closeAll: Bool = false, now: Date = Date()) throws -> [Recording] {
        let journals = RecordJournal.all(in: layout.stateFolder)
        var ledger = Ledger.load(from: layout.ledgerURL)

        var trusted: [[TimedRecord]] = []
        var apart: [(segment: Segment, over: Bool)] = []
        for journal in journals {
            try journal.settleClock()
            let held = journal.heldFrom
            let records = journal.load().filter { record in
                !ledger.covers(journal: journal.key, seq: record.seq) && (held.map { record.seq < $0 } ?? true)
            }
            let timed = ClockCorrection.apply(records, entries: journal.clock, journal: journal.key)
            trusted.append(timed.filter { $0.time != nil && !$0.unreliable })
            // Records whose time isn't known stay out of the line, as
            // recordings of their own. One between two restarts is over by
            // definition; one made with no clock is over once its journal
            // has been quiet for a minute.
            let quiet = journal.lastAppend.map { now.timeIntervalSince($0) > Segmenter.gap } ?? true
            for segment in Segmenter.split(timed.filter { $0.time == nil || $0.unreliable }) {
                apart.append((segment, segment.unreliable || quiet))
            }
        }

        var written: [Recording] = []
        func finish(_ segment: Segment) throws {
            let recording = try write(segment, device: device, firmware: firmware, now: now)
            ledger.recordings.append(recording)
            try ledger.save(to: layout.ledgerURL)
            written.append(recording)
        }
        for segment in Segmenter.split(Segmenter.merge(trusted)) {
            guard let end = segment.end, closeAll || now.timeIntervalSince(end) > Segmenter.gap else { continue }
            try finish(segment)
        }
        for (segment, over) in apart where closeAll || over {
            try finish(segment)
        }

        // What is in a recording, and in the ledger, can leave the journals.
        for journal in journals {
            try journal.keep { !ledger.covers(journal: journal.key, seq: $0.seq) }
            try journal.settleClock()
        }
        return written
    }

    private func write(_ segment: Segment, device: String, firmware: String?, now: Date) throws -> Recording {
        let frames = segment.frames
        let seconds = Double(frames.map { OpusPacket.samples($0) ?? 960 }.reduce(0, +)) / 48_000
        var note: String?
        let start: Date
        if let known = segment.start {
            start = known
            if segment.unreliable {
                note = "The pendant restarted more than once before this was copied, so this time may be hours early."
            } else if segment.correction != 0 {
                let amount = RecordingLayout.length(abs(segment.correction))
                note = "The pendant's clock was \(amount) \(segment.correction > 0 ? "behind" : "ahead") when this was copied. The time here is corrected."
            }
        } else {
            start = now.addingTimeInterval(-seconds)
            note = "The pendant's clock wasn't set when this was recorded. The time here is a guess: when it was copied, less its length."
        }

        let manager = FileManager.default
        let day = layout.dayFolder(for: start)
        try manager.createDirectory(at: day, withIntermediateDirectories: true)
        try manager.createDirectory(at: layout.incomingFolder, withIntermediateDirectories: true)
        let base = layout.baseName(for: start) { name in
            manager.fileExists(atPath: day.appendingPathComponent("\(name).opus").path)
                || manager.fileExists(atPath: day.appendingPathComponent("\(name).md").path)
        }

        let temporary = layout.incomingFolder.appendingPathComponent("\(UUID().uuidString).opus")
        let writer = try OggOpusWriter(url: temporary, inputSampleRate: 16_000,
                                       tags: ["DATE": ISO8601DateFormatter().string(from: start), "TITLE": base, "ARTIST": device])
        for frame in frames { try writer.append(frame) }
        try writer.finish()
        let audio = day.appendingPathComponent("\(base).opus")
        try manager.moveItem(at: temporary, to: audio)
        let bytes = (try? manager.attributesOfItem(atPath: audio.path))?[.size] as? Int ?? 0

        let recording = Recording(file: "\(day.lastPathComponent)/\(audio.lastPathComponent)", start: start,
                                  seconds: seconds, bytes: bytes, device: device, firmware: firmware,
                                  clockNote: note, importedAt: now,
                                  spans: segment.spans)
        try Data(layout.note(for: recording, audioFile: audio.lastPathComponent).utf8)
            .write(to: day.appendingPathComponent("\(base).md"), options: .atomic)
        return recording
    }
}
