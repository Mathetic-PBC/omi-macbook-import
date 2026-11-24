import Foundation

/// How long an Opus packet plays, read off its first byte (the TOC byte,
/// RFC 6716 §3.1), in samples at 48 kHz. Ogg Opus counts time in 48 kHz
/// samples whatever rate the audio was encoded at (RFC 7845 §4).
public enum OpusPacket {
    /// Frame length in 48 kHz samples for each of the 32 configurations.
    private static func frameSamples(config: Int) -> Int {
        switch config {
        case 0...11: // SILK: 10, 20, 40, 60 ms
            return [480, 960, 1920, 2880][config & 3]
        case 12...15: // Hybrid: 10 or 20 ms
            return config & 1 == 0 ? 480 : 960
        default: // CELT: 2.5, 5, 10, 20 ms
            return [120, 240, 480, 960][config & 3]
        }
    }

    /// Samples at 48 kHz, or nil for a packet too short to say.
    public static func samples(_ packet: Data) -> Int? {
        guard let toc = packet.first else { return nil }
        let frame = frameSamples(config: Int(toc >> 3))
        switch toc & 3 {
        case 0: return frame
        case 1, 2: return frame * 2
        default:
            guard packet.count >= 2 else { return nil }
            let count = Int(packet[packet.startIndex + 1] & 0x3F)
            return count == 0 ? nil : frame * count
        }
    }
}

/// Writes Opus packets, as they came from the pendant, into an Ogg Opus file
/// (RFC 7845) without decoding them. The audio is the pendant's own bytes:
/// nothing is re-encoded, so nothing is lost, and an hour is about 14 MB.
public final class OggOpusWriter {
    public let url: URL
    private let handle: FileHandle
    private let serial: UInt32
    private var sequence: UInt32 = 0
    private var granule: Int64 = 0
    private var segments: [UInt8] = []
    private var body = Data()
    private var pagePackets = 0
    private var closed = false

    /// Pages are cut at about this much audio, so a player can seek.
    private let pageSamples: Int64 = 48_000
    private var pageStartGranule: Int64 = 0

    public private(set) var packetCount = 0
    public var durationSeconds: Double { Double(granule) / 48_000 }

    public init(url: URL, inputSampleRate: UInt32, channels: UInt8 = 1, tags: [String: String] = [:]) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        serial = UInt32.random(in: 1...UInt32.max)

        var head = Data("OpusHead".utf8)
        head.append(1) // version
        head.append(channels)
        head.appendLE(UInt16(0)) // pre-skip: the pendant's encoder delay is unknown; a few ms of warm-up are played
        head.appendLE(inputSampleRate)
        head.appendLE(UInt16(0)) // output gain
        head.append(0) // mapping family 0: mono or stereo
        try writePage(packets: [head], granule: 0, flags: 0x02)

        var comments = Data("OpusTags".utf8)
        let vendor = Data("omi-macbook-import".utf8)
        comments.appendLE(UInt32(vendor.count))
        comments.append(vendor)
        let pairs = tags.sorted { $0.key < $1.key }.map { Data("\($0.key)=\($0.value)".utf8) }
        comments.appendLE(UInt32(pairs.count))
        for pair in pairs {
            comments.appendLE(UInt32(pair.count))
            comments.append(pair)
        }
        try writePage(packets: [comments], granule: 0, flags: 0)
    }

    /// Adds one Opus packet. A packet whose length can't be read off its TOC
    /// byte is counted as `fallbackSamples`.
    public func append(_ packet: Data, fallbackSamples: Int = 960) throws {
        precondition(!closed)
        guard !packet.isEmpty else { return }
        let lacing = Self.lacing(for: packet.count)
        if segments.count + lacing.count > 255 { try flush(flags: 0) }
        segments += lacing
        body.append(packet)
        pagePackets += 1
        packetCount += 1
        granule += Int64(OpusPacket.samples(packet) ?? fallbackSamples)
        if granule - pageStartGranule >= pageSamples { try flush(flags: 0) }
    }

    /// Ends the stream and the file. Writes everything to disk before it returns.
    public func finish() throws {
        guard !closed else { return }
        closed = true
        if pagePackets > 0 {
            try flush(flags: 0x04)
        } else {
            // No audio after the headers: an empty last page carries the end mark.
            try writeRaw(segments: [], body: Data(), granule: granule, flags: 0x04)
        }
        try handle.synchronize()
        try handle.close()
    }

    private func flush(flags: UInt8) throws {
        guard pagePackets > 0 else { return }
        try writeRaw(segments: segments, body: body, granule: granule, flags: flags)
        segments = []
        body = Data()
        pagePackets = 0
        pageStartGranule = granule
    }

    private func writePage(packets: [Data], granule: Int64, flags: UInt8) throws {
        var lacing: [UInt8] = []
        var data = Data()
        for packet in packets {
            lacing += Self.lacing(for: packet.count)
            data.append(packet)
        }
        try writeRaw(segments: lacing, body: data, granule: granule, flags: flags)
    }

    private func writeRaw(segments: [UInt8], body: Data, granule: Int64, flags: UInt8) throws {
        var page = Data("OggS".utf8)
        page.append(0) // stream structure version
        page.append(flags)
        page.appendLE(UInt64(bitPattern: granule))
        page.appendLE(serial)
        page.appendLE(sequence)
        page.appendLE(UInt32(0)) // CRC, filled in below
        page.append(UInt8(segments.count))
        page.append(contentsOf: segments)
        page.append(body)
        let crc = OggCRC.checksum(page)
        page.replaceSubrange(22..<26, with: withUnsafeBytes(of: crc.littleEndian) { Data($0) })
        try handle.write(contentsOf: page)
        sequence += 1
    }

    /// A packet of n bytes is n/255 segments of 255 and one of the rest,
    /// which is 0 when n is a multiple of 255 (RFC 3533 §6).
    static func lacing(for length: Int) -> [UInt8] {
        Array(repeating: 255, count: length / 255) + [UInt8(length % 255)]
    }
}

/// The CRC Ogg pages carry: polynomial 0x04C11DB7, no reflection, starting
/// from zero (RFC 3533 §6).
public enum OggCRC {
    private static let table: [UInt32] = (0..<256).map { index in
        var r = UInt32(index) << 24
        for _ in 0..<8 { r = r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc = (crc << 8) ^ table[Int(((crc >> 24) & 0xFF) ^ UInt32(byte))]
        }
        return crc
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
