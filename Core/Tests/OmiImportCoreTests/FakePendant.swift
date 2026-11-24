import Foundation
@testable import OmiImportCore

/// A pendant's storage service, as the firmware behaves (storage.c), for
/// driving a drain without a pendant. `modern` is 3.0.24 and later: a 41-byte
/// INFO with a ring id, and records freed only by ADVANCE_ID. Otherwise it is
/// 3.0.21: a 31-byte INFO, and records freed as they are sent.
final class FakePendant {
    var modern: Bool
    var ringID: UInt64 = 0x1122_3344_5566_7788
    var records: [Data] = [] // the ring, from seq `base`
    var base: UInt64 = 0 // read_seq
    var chunk = 240 // bytes of records per DATA notification (MTU - 4)
    var deliver: (Data) -> Void = { _ in }
    var commands: [Data] = []
    /// Stop answering after this many DATA notifications (a lost connection).
    var dropAfterData: Int?
    /// Swallow the next ADVANCE without acting or answering.
    var ignoreAdvances = 0
    /// Lose one DATA notification in the next transfer.
    var loseOneNotification = false
    private var dataSent = 0

    init(modern: Bool) { self.modern = modern }

    var writeSeq: UInt64 { base + UInt64(records.count) }

    func add(_ record: Data) { records.append(record) }

    private func notify(_ bytes: [UInt8]) { deliver(Data(bytes)) }

    private func be(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * $0)) } }
    private func be(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) } }

    private func free(to seq: UInt64) {
        guard seq > base else { return }
        let count = Int(min(seq, writeSeq) - base)
        records.removeFirst(count)
        base += UInt64(count)
    }

    func write(_ command: Data) {
        commands.append(command)
        let bytes = [UInt8](command)
        switch bytes[0] {
        case 0x10:
            var info: [UInt8] = [0x02] + be(base) + be(writeSeq) + be(UInt32(100_000)) + be(UInt64(0)) + [0x01, 0xBC]
            if modern { info += [0x0F, 0x01] + be(ringID) }
            notify(info)
        case 0x11:
            let start = bytes.be64(1)
            var count = bytes.count == 13 ? Int(bytes.be32(9)) : 0
            guard start >= base, start <= writeSeq else { notify([0x01, 10]); return }
            let available = Int(writeSeq - start)
            if count == 0 || count > available { count = available }
            notify([0x05] + be(start) + be(UInt32(count)))
            let first = Int(start - base)
            let blob = records[first..<(first + count)].reduce(into: Data()) { $0.append($1) }
            var offset = 0
            var lost = false
            while offset < blob.count {
                if let limit = dropAfterData, dataSent >= limit { return } // gone quiet
                let end = min(offset + chunk, blob.count)
                if loseOneNotification, !lost, offset > 0 {
                    lost = true
                    loseOneNotification = false
                } else {
                    notify([0x03] + [UInt8](blob[offset..<end]))
                }
                dataSent += 1
                offset = end
            }
            // 3.0.21 frees what it sent, without being asked.
            if !modern { free(to: start + UInt64(count)) }
            notify([0x04, 0x00] + be(start + UInt64(count)))
        case 0x12:
            if ignoreAdvances > 0 { ignoreAdvances -= 1; return }
            let seq = bytes.be64(1)
            if modern {
                if seq > writeSeq { notify([0x01, 10]); return }
                free(to: seq)
                notify([0x01, 0])
            } else {
                // Already freed: the firmware answers out of range, or OK.
                notify([0x01, seq > writeSeq ? 10 : 0])
            }
        case 0x15:
            guard modern else { notify([0x01, 6]); return }
            if ignoreAdvances > 0 { ignoreAdvances -= 1; return }
            let ring = bytes.be64(1), seq = bytes.be64(9)
            if ring != ringID { notify([0x01, 11]); return }
            if seq > writeSeq { notify([0x01, 10]); return }
            free(to: seq)
            notify([0x01, 0])
        case 0x03:
            notify([0x01, 0])
        default:
            notify([0x01, 6])
        }
    }
}

/// Packs Opus frames into 444-byte records the way the firmware does
/// (transport.c `write_to_storage`): `[len][frame]` entries, and a new record
/// when the next entry would run past byte 439.
enum RecordMaker {
    /// `dangling`: 3.0.21 writes the length of the frame that didn't fit
    /// where it would have gone, and leaves stale bytes after it.
    static func record(time: UInt32, frames: [Data], dangling: UInt8? = nil) -> Data {
        var payload = Data()
        for frame in frames {
            payload.append(UInt8(frame.count))
            payload.append(frame)
        }
        precondition(payload.count < PendantRecord.payloadSize)
        if let dangling {
            precondition(payload.count + 1 + Int(dangling) >= PendantRecord.payloadSize)
            payload.append(dangling)
            payload.append(Data(repeating: 0xEE, count: PendantRecord.payloadSize - payload.count))
        } else {
            payload.append(Data(repeating: 0, count: PendantRecord.payloadSize - payload.count))
        }
        var record = Data()
        record.appendBE(time)
        record.append(payload)
        return record
    }

    /// `seconds` of audio starting at `start`, as records stamped the way the
    /// pendant stamps them (when written, in whole seconds). Frames are 20 ms.
    static func records(frames source: [Data], start: UInt32, seconds: Int, legacyTail: Bool = false) -> [Data] {
        var records: [Data] = []
        var batch: [Data] = []
        var size = 0
        var index = 0
        let total = seconds * 50
        for n in 0..<total {
            let frame = source[index % source.count]
            index += 1
            if size + 1 + frame.count > PendantRecord.payloadSize - 1 {
                records.append(record(time: start + UInt32(n / 50), frames: batch,
                                      dangling: legacyTail ? UInt8(frame.count) : nil))
                batch = []
                size = 0
            }
            batch.append(frame)
            size += 1 + frame.count
        }
        if !batch.isEmpty { records.append(record(time: start + UInt32(seconds), frames: batch)) }
        return records
    }
}
