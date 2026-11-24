import Foundation

/// The pendant's storage protocol (firmware 3.0.20 and later), as read from
/// BasedHardware/omi `omi/firmware/omi/src/lib/core/storage.c`. See
/// docs/protocol.md for the whole of it and where each part comes from.
///
/// The pendant keeps one ring of 444-byte records on its SD card. Each record
/// has a sequence number; `read_seq` is the oldest one not yet freed and
/// `write_seq` the next one to be written. Commands are written to one
/// characteristic and every reply comes back as a notification on it.
public enum StorageCommand {
    public static func info() -> Data { Data([0x10]) }

    /// Read `count` records from `start`. The pendant answers READ_BEGIN,
    /// then DATA notifications, then DONE.
    public static func read(from start: UInt64, count: UInt32) -> Data {
        var data = Data([0x11])
        data.appendBE(start)
        data.appendBE(count)
        return data
    }

    /// Frees every record before `seq` (firmware before 3.0.24).
    public static func advance(to seq: UInt64) -> Data {
        var data = Data([0x12])
        data.appendBE(seq)
        return data
    }

    /// Frees every record before `seq`, only if the ring is still `ring`
    /// (3.0.24 and later).
    public static func advance(ring: UInt64, to seq: UInt64) -> Data {
        var data = Data([0x15])
        data.appendBE(ring)
        data.appendBE(seq)
        return data
    }

    public static func stop() -> Data { Data([0x03]) }
}

public struct RingInfo: Equatable {
    public var readSeq: UInt64
    public var writeSeq: UInt64
    public var capacity: UInt32
    public var dropped: UInt64
    public var recordSize: UInt16
    /// 0 on firmware before 3.0.24. Bit 0x01: the pendant frees records only
    /// when told to; 0x02: it can keep live audio too; 0x08: rings have ids.
    public var capabilities: UInt8
    /// Set from 3.0.24 on. A different id means the ring was wiped and its
    /// sequence numbers started again.
    public var ringID: UInt64?

    public var unread: UInt64 { writeSeq > readSeq ? writeSeq - readSeq : 0 }
    /// Firmware that keeps a record until the app confirms it (3.0.24+).
    public var freesOnConfirmation: Bool { capabilities & 0x01 != 0 }
}

public enum StorageReply: Equatable {
    case ack(status: UInt8)
    case info(RingInfo)
    case readBegin(start: UInt64, count: UInt32)
    case data(Data)
    case done(status: UInt8, next: UInt64)
    case liveMark
    case unknown(Data)

    public static let ok: UInt8 = 0
    public static let invalidCommand: UInt8 = 6
    public static let notReady: UInt8 = 9
    public static let outOfRange: UInt8 = 10
    public static let ringMismatch: UInt8 = 11

    public static func parse(_ data: Data) -> StorageReply {
        let bytes = [UInt8](data)
        guard let tag = bytes.first else { return .unknown(data) }
        switch tag {
        case 0x01 where bytes.count >= 2:
            return .ack(status: bytes[1])
        case 0x02 where bytes.count >= 31:
            let ringID: UInt64? = bytes.count >= 41 ? bytes.be64(33) : nil
            return .info(RingInfo(readSeq: bytes.be64(1), writeSeq: bytes.be64(9), capacity: bytes.be32(17),
                                  dropped: bytes.be64(21), recordSize: bytes.be16(29),
                                  capabilities: bytes.count >= 32 ? bytes[31] : 0, ringID: ringID))
        case 0x03:
            return .data(Data(bytes.dropFirst()))
        case 0x04 where bytes.count >= 10:
            return .done(status: bytes[1], next: bytes.be64(2))
        case 0x05 where bytes.count >= 13:
            return .readBegin(start: bytes.be64(1), count: bytes.be32(9))
        case 0x06:
            return .liveMark
        default:
            return .unknown(data)
        }
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

extension Array where Element == UInt8 {
    func be16(_ at: Int) -> UInt16 { UInt16(self[at]) << 8 | UInt16(self[at + 1]) }
    func be32(_ at: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(self[at + $1]) } }
    func be64(_ at: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(self[at + $1]) } }
}
