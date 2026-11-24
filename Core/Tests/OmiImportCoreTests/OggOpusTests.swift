import XCTest
@testable import OmiImportCore

/// A minimal Ogg reader, for checking what the writer wrote.
struct OggPage {
    var flags: UInt8
    var granule: Int64
    var sequence: UInt32
    var storedCRC: UInt32
    var computedCRC: UInt32
    var packets: [Data] // packets that end on this page (continued packets are joined)
}

func readOgg(_ data: Data) throws -> (pages: [OggPage], packets: [Data]) {
    var pages: [OggPage] = []
    var packets: [Data] = []
    var pending = Data()
    var at = data.startIndex
    func le<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size { value |= T(data[offset + i]) << (8 * i) }
        return value
    }
    while at < data.endIndex {
        guard data[at..<at + 4] == Data("OggS".utf8) else { throw NSError(domain: "ogg", code: 1) }
        let flags = data[at + 5]
        let granule = Int64(bitPattern: le(at + 6, UInt64.self))
        let sequence: UInt32 = le(at + 18, UInt32.self)
        let crc: UInt32 = le(at + 22, UInt32.self)
        let count = Int(data[at + 26])
        let table = Array(data[at + 27..<at + 27 + count])
        let bodyStart = at + 27 + count
        let bodyLength = table.reduce(0) { $0 + Int($1) }
        var page = Data(data[at..<bodyStart + bodyLength])
        page.replaceSubrange(22..<26, with: Data(repeating: 0, count: 4))
        var ended: [Data] = []
        var cursor = bodyStart
        for lace in table {
            pending.append(data[cursor..<cursor + Int(lace)])
            cursor += Int(lace)
            if lace < 255 {
                ended.append(pending)
                packets.append(pending)
                pending = Data()
            }
        }
        pages.append(OggPage(flags: flags, granule: granule, sequence: sequence, storedCRC: crc,
                             computedCRC: OggCRC.checksum(page), packets: ended))
        at = bodyStart + bodyLength
    }
    return (pages, packets)
}

final class OggOpusTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "opus", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// The CRC matches what libogg (via ffmpeg) wrote on every page of a real file.
    func testCRCMatchesRealFiles() throws {
        for name in ["sine-10ms", "voice-20ms"] {
            let (pages, _) = try readOgg(try fixture(name))
            XCTAssertGreaterThan(pages.count, 2)
            for page in pages { XCTAssertEqual(page.storedCRC, page.computedCRC, "\(name) page \(page.sequence)") }
        }
    }

    /// Packet lengths read off the TOC byte add up to the stream's last granule
    /// position (which counts pre-skip too, so the difference is the pre-skip).
    func testTOCDurationsAddUpToGranule() throws {
        for (name, frame) in [("sine-10ms", 480), ("voice-20ms", 960)] {
            let (pages, packets) = try readOgg(try fixture(name))
            let audio = Array(packets.dropFirst(2))
            XCTAssertTrue(audio.allSatisfy { OpusPacket.samples($0) == frame }, name)
            let total = audio.compactMap(OpusPacket.samples).reduce(0, +)
            let head = packets[0]
            let preSkip = Int(head[10]) | Int(head[11]) << 8
            // ffmpeg trims the last page's granule to the true end of the audio,
            // so the packets cover at least that much and less than one frame more.
            let last = Int(pages.last!.granule)
            XCTAssertGreaterThanOrEqual(total, last)
            XCTAssertLessThan(total - last, frame + preSkip, name)
        }
    }

    func testTOCConfigurations() {
        // config 31 (CELT 20 ms), one frame
        XCTAssertEqual(OpusPacket.samples(Data([31 << 3])), 960)
        // config 28 (CELT 2.5 ms), two frames (c = 1)
        XCTAssertEqual(OpusPacket.samples(Data([28 << 3 | 1])), 240)
        // config 1 (SILK 20 ms), code 3 with 3 frames
        XCTAssertEqual(OpusPacket.samples(Data([1 << 3 | 3, 3])), 2880)
        // config 13 (hybrid 20 ms)
        XCTAssertEqual(OpusPacket.samples(Data([13 << 3])), 960)
        XCTAssertNil(OpusPacket.samples(Data()))
        XCTAssertNil(OpusPacket.samples(Data([3])))
    }

    /// Packets taken out of a real file and written again come back byte for
    /// byte, on pages with valid CRCs, a start mark, an end mark, and a final
    /// granule equal to the packets' total length.
    func testRemuxRoundTrip() throws {
        let (_, source) = try readOgg(try fixture("sine-10ms"))
        let audio = Array(source.dropFirst(2))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remux-\(UUID().uuidString).opus")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try OggOpusWriter(url: url, inputSampleRate: 16_000, tags: ["DATE": "2026-11-23T14:05:12-08:00"])
        for packet in audio { try writer.append(packet) }
        try writer.finish()

        let (pages, packets) = try readOgg(try Data(contentsOf: url))
        XCTAssertEqual(Array(packets.dropFirst(2)), audio)
        XCTAssertTrue(packets[0].starts(with: Data("OpusHead".utf8)))
        XCTAssertTrue(packets[1].starts(with: Data("OpusTags".utf8)))
        XCTAssertEqual(pages.first?.flags, 0x02)
        XCTAssertEqual(pages.last?.flags, 0x04)
        XCTAssertEqual(pages.map(\.sequence), Array(0..<UInt32(pages.count)))
        for page in pages { XCTAssertEqual(page.storedCRC, page.computedCRC) }
        XCTAssertEqual(pages.last?.granule, Int64(audio.count * 480))
        XCTAssertEqual(writer.durationSeconds, Double(audio.count * 480) / 48_000, accuracy: 0.0001)
    }

    /// A packet longer than 255 bytes, and one exactly 255 long, lace correctly.
    func testLacing() throws {
        XCTAssertEqual(OggOpusWriter.lacing(for: 0), [0])
        XCTAssertEqual(OggOpusWriter.lacing(for: 100), [100])
        XCTAssertEqual(OggOpusWriter.lacing(for: 255), [255, 0])
        XCTAssertEqual(OggOpusWriter.lacing(for: 600), [255, 255, 90])

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lacing-\(UUID().uuidString).opus")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try OggOpusWriter(url: url, inputSampleRate: 16_000)
        let packets = [Data([31 << 3]) + Data(repeating: 7, count: 254),
                       Data([31 << 3]) + Data(repeating: 9, count: 599)]
        for packet in packets { try writer.append(packet) }
        try writer.finish()
        let (_, read) = try readOgg(try Data(contentsOf: url))
        XCTAssertEqual(Array(read.dropFirst(2)), packets)
    }

    /// A stream with no audio still ends properly.
    func testEmptyStream() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).opus")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try OggOpusWriter(url: url, inputSampleRate: 16_000)
        try writer.finish()
        let (pages, packets) = try readOgg(try Data(contentsOf: url))
        XCTAssertEqual(packets.count, 2) // head and tags; the end page holds no packet
        XCTAssertEqual(pages.last?.flags, 0x04)
    }
}
