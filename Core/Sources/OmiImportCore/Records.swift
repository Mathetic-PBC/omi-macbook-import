import Foundation

/// One 444-byte record from the pendant's ring: a 4-byte big-endian
/// timestamp and 440 bytes of `[length][Opus frame]` entries, zero-padded.
public struct PendantRecord: Equatable {
    public static let size = 444
    public static let payloadSize = 440
    /// Set in a timestamp that counts seconds since the pendant started,
    /// because its clock wasn't set (3.0.24+; 3.0.21 stores nothing then).
    public static let uptimeFlag: UInt32 = 0x8000_0000

    public var seq: UInt64
    public var bytes: Data

    public init(seq: UInt64, bytes: Data) {
        self.seq = seq
        self.bytes = bytes
    }

    public var rawTimestamp: UInt32 {
        let b = [UInt8](bytes.prefix(4))
        return b.count == 4 ? b.be32(0) : 0
    }

    /// The time the record was written, which is about when its audio ended;
    /// nil when the pendant's clock wasn't set.
    public var time: Date? {
        let raw = rawTimestamp
        guard raw != 0, raw & Self.uptimeFlag == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(raw))
    }

    /// The Opus frames in the record. A zero length byte is padding. A length
    /// that would run to the end of the payload is the firmware's dangling
    /// length byte (its frame went into the next record), and what follows it
    /// is stale, so parsing stops there. The same rule as the official app's
    /// `RingProtocol.parseAudioPayload`.
    public var frames: [Data] {
        let payload = [UInt8](bytes.dropFirst(4).prefix(Self.payloadSize))
        var frames: [Data] = []
        var offset = 0
        while offset < payload.count - 1 {
            let length = Int(payload[offset])
            if length == 0 { offset += 1; continue }
            if offset + 1 + length >= payload.count { break }
            frames.append(Data(payload[(offset + 1)..<(offset + 1 + length)]))
            offset += 1 + length
        }
        return frames
    }
}

/// A record with the time it was really written: the pendant's stamp, put
/// right where the pendant's clock is known to have been off.
public struct TimedRecord: Equatable {
    /// The journal it is in.
    public var journal: String
    public var record: PendantRecord
    /// Nil when the pendant's clock wasn't set.
    public var time: Date?
    /// Seconds added to the pendant's stamp to get `time`.
    public var correction: TimeInterval = 0
    /// The stamp can't be trusted and can't be put right.
    public var unreliable = false

    public init(journal: String, record: PendantRecord, time: Date?, correction: TimeInterval = 0, unreliable: Bool = false) {
        self.journal = journal
        self.record = record
        self.time = time
        self.correction = correction
        self.unreliable = unreliable
    }
}

/// A stretch of records that make one recording.
public struct Segment: Equatable {
    public var records: [TimedRecord]
    public var frames: [Data] { records.flatMap(\.record.frames) }
    /// The largest clock correction made to any record in it.
    public var correction: TimeInterval { records.map(\.correction).max { abs($0) < abs($1) } ?? 0 }
    public var unreliable: Bool { records.first?.unreliable ?? false }

    /// When the audio began: the first record's time less the audio it holds
    /// (a record is stamped as it is written, so at the end of its audio).
    /// Nil for a recording made while the pendant's clock wasn't set.
    public var start: Date? {
        guard let first = records.first, let time = first.time else { return nil }
        let audio = first.record.frames.compactMap(OpusPacket.samples).reduce(0, +)
        return time.addingTimeInterval(-Double(audio) / 48_000)
    }

    /// The time of the last record, about when the audio ended.
    public var end: Date? { records.last?.time }

    /// The runs of consecutive records it is made of, journal by journal. A
    /// run never reaches over a record that isn't in the recording.
    public var spans: [Recording.Span] {
        var spans: [Recording.Span] = []
        for record in records {
            if let last = spans.last, last.journal == record.journal, record.record.seq == last.last + 1 {
                spans[spans.count - 1].last = record.record.seq
            } else {
                spans.append(.init(journal: record.journal, first: record.record.seq, last: record.record.seq))
            }
        }
        return spans
    }
}

public enum Segmenter {
    /// The official app's rule: a new recording starts where the timestamps
    /// jump forward by more than a minute, or go backwards. The pendant's
    /// microphone sleeps through silence, so a pause shows up as a jump.
    public static let gap: TimeInterval = 60
    /// A step back smaller than this is the clock being nudged, not a restart.
    public static let backwards: TimeInterval = 5

    /// Splits records, in the order they were recorded, into recordings, by
    /// their corrected times. A run of records made while the pendant's clock
    /// wasn't set, or whose times can't be trusted, is a recording of its own.
    public static func split(_ records: [TimedRecord]) -> [Segment] {
        var segments: [Segment] = []
        var current: [TimedRecord] = []
        for record in records where !record.record.frames.isEmpty {
            if let last = current.last {
                var breakHere = (last.time == nil) != (record.time == nil) || last.unreliable != record.unreliable
                if let time = record.time, let before = last.time {
                    let step = time.timeIntervalSince(before)
                    if step > gap || step < -backwards { breakHere = true }
                }
                if last.time == nil, last.journal != record.journal { breakHere = true }
                if breakHere {
                    segments.append(Segment(records: current))
                    current = []
                }
            }
            current.append(record)
        }
        if !current.isEmpty { segments.append(Segment(records: current)) }
        return segments
    }

    /// Puts the records of several journals in one line, by time. Each
    /// journal's own order is kept: at every step the journal whose next
    /// record is earliest gives it. This is how audio stored on the pendant
    /// and audio heard live while it was connected come back together.
    public static func merge(_ journals: [[TimedRecord]]) -> [TimedRecord] {
        var heads = journals.map { $0.startIndex }
        var merged: [TimedRecord] = []
        merged.reserveCapacity(journals.reduce(0) { $0 + $1.count })
        while true {
            var pick: Int?
            for index in journals.indices where heads[index] < journals[index].endIndex {
                guard let time = journals[index][heads[index]].time else { pick = pick ?? index; continue }
                if let current = pick, let best = journals[current][heads[current]].time, best <= time { continue }
                pick = index
            }
            guard let pick else { break }
            merged.append(journals[pick][heads[pick]])
            heads[pick] += 1
        }
        return merged
    }
}

/// Putting the pendant's clock right.
///
/// The pendant has no clock of its own: it counts up from the last time a
/// phone or Mac told it the time, and after it restarts it counts up from
/// that same moment again, so everything it records until it is next told
/// the time is stamped too early by however long it was off. Each time this
/// Mac connects it compares the pendant's clock with its own before setting
/// it, and keeps the difference with the sequence number the ring had
/// reached: every record before that number was stamped by the old clock.
public struct ClockEntry: Codable, Equatable {
    /// Records with a sequence number below this were stamped by the old clock.
    public var boundary: UInt64
    /// The pendant's clock less this Mac's, in seconds, when it was compared.
    public var drift: Double
    public var at: Date
    /// Every record below `boundary` has been copied.
    public var complete: Bool

    public init(boundary: UInt64, drift: Double, at: Date, complete: Bool = false) {
        self.boundary = boundary
        self.drift = drift
        self.at = at
        self.complete = complete
    }
}

public enum ClockCorrection {
    /// A difference smaller than this isn't worth correcting.
    public static let threshold: TimeInterval = 5

    /// The records of one ring, in sequence order, with their times put right.
    ///
    /// Within the records an entry covers, a step backwards in the stamps is
    /// where the pendant restarted. Records after the last restart are off by
    /// exactly the measured difference. Records before the first were stamped
    /// by a clock this Mac had set, and are left alone. Records between two
    /// restarts are off by an amount nobody measured, and are marked.
    public static func apply(_ records: [PendantRecord], entries: [ClockEntry], journal: String = "") -> [TimedRecord] {
        var timed = records.map { TimedRecord(journal: journal, record: $0, time: $0.time) }
        var lower: UInt64 = 0
        for entry in entries.sorted(by: { $0.boundary < $1.boundary }) {
            defer { lower = max(lower, entry.boundary) }
            guard abs(entry.drift) > threshold else { continue }
            let indices = timed.indices.filter { timed[$0].record.seq >= lower && timed[$0].record.seq < entry.boundary && timed[$0].time != nil }
            var restarts: [Int] = [] // positions in `indices` where the stamps step back
            for position in indices.indices.dropFirst() {
                let step = timed[indices[position]].time!.timeIntervalSince(timed[indices[position - 1]].time!)
                if step < -Segmenter.backwards { restarts.append(position) }
            }
            for (position, index) in indices.enumerated() {
                if let last = restarts.last, position < last {
                    if let first = restarts.first, position >= first { timed[index].unreliable = true }
                    continue
                }
                timed[index].correction = -entry.drift
                timed[index].time = timed[index].time?.addingTimeInterval(-entry.drift)
            }
        }
        return timed
    }
}

/// Turns live audio notifications into records shaped like the pendant's
/// own, so audio heard live goes through the same path as stored audio.
///
/// A live notification is `[index u16 LE][fragment u8][bytes]`. A frame
/// longer than one notification is split across several, numbered 0, 1, …
/// (firmware transport.c `push_to_gatt`); a fragment 0 starts a new frame.
public struct LivePacker {
    private var frame = Data()
    private var payload = Data()
    private var payloadTime: UInt32 = 0
    private var lastFrameAt: Date?

    public init() {}

    /// Takes one notification; returns any records it completed.
    public mutating func receive(_ notification: Data, at now: Date) -> [Data] {
        let bytes = [UInt8](notification)
        guard bytes.count > 3 else { return [] }
        var out: [Data] = []
        if bytes[2] == 0, !frame.isEmpty {
            out += add(frame, at: now)
            frame = Data()
        }
        frame.append(contentsOf: bytes[3...])
        return out
    }

    /// The pendant packs a record until the next frame wouldn't fit, or after
    /// a second with no audio. Call this about once a second.
    public mutating func tick(at now: Date) -> [Data] {
        guard let lastFrameAt, now.timeIntervalSince(lastFrameAt) >= 1 else { return [] }
        var out: [Data] = []
        if !frame.isEmpty {
            out += add(frame, at: lastFrameAt)
            frame = Data()
        }
        if let record = flush() { out.append(record) }
        self.lastFrameAt = nil
        return out
    }

    private mutating func add(_ frame: Data, at now: Date) -> [Data] {
        guard frame.count < 256 else { return [] } // a length byte can't say more
        var out: [Data] = []
        // Keep the last byte of the payload zero, as 3.0.24 does.
        if payload.count + 1 + frame.count > PendantRecord.payloadSize - 1, let record = flush() {
            out.append(record)
        }
        payload.append(UInt8(frame.count))
        payload.append(frame)
        payloadTime = UInt32(now.timeIntervalSince1970)
        lastFrameAt = now
        return out
    }

    private mutating func flush() -> Data? {
        guard !payload.isEmpty else { return nil }
        var record = Data()
        record.appendBE(payloadTime)
        record.append(payload)
        record.append(Data(repeating: 0, count: PendantRecord.payloadSize - payload.count))
        payload = Data()
        return record
    }
}
