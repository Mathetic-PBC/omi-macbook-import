import Foundation

/// Where recordings go in the import folder, and the note beside each one.
///
///     <folder>/2026-11-23/2026-11-23 14-05-12.opus   the audio, as the pendant encoded it
///     <folder>/2026-11-23/2026-11-23 14-05-12.md     when, how long, from what; later its transcript
///     <folder>/.omi-import/ledger.json               what has been imported (hidden from Engelbart)
///
/// One folder a day, because a day is how the recordings will be looked
/// through. The markdown note is what makes a recording findable in
/// Engelbart, which lists markdown but not audio.
public struct RecordingLayout {
    public let folder: URL
    public let timeZone: TimeZone

    public init(folder: URL, timeZone: TimeZone = .current) {
        self.folder = folder
        self.timeZone = timeZone
    }

    private func format(_ pattern: String, _ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    public func dayFolder(for start: Date) -> URL {
        folder.appendingPathComponent(format("yyyy-MM-dd", start), isDirectory: true)
    }

    /// The name both files share. A second recording starting in the same
    /// second gets " 2", " 3" and so on.
    public func baseName(for start: Date, existing: (String) -> Bool) -> String {
        let base = format("yyyy-MM-dd HH-mm-ss", start)
        var name = base
        var counter = 2
        while existing(name) {
            name = "\(base) \(counter)"
            counter += 1
        }
        return name
    }

    public var stateFolder: URL { folder.appendingPathComponent(".omi-import", isDirectory: true) }
    public var ledgerURL: URL { stateFolder.appendingPathComponent("ledger.json") }
    /// Where a transfer in progress writes before it is complete.
    public var incomingFolder: URL { stateFolder.appendingPathComponent("incoming", isDirectory: true) }

    public func note(for recording: Recording, audioFile: String) -> String {
        let start = format("yyyy-MM-dd HH:mm:ss xxx", recording.start)
        let heading = format("EEEE d MMMM yyyy, HH:mm", recording.start)
        var lines = [
            "# Omi · \(heading)",
            "",
            "- Started: \(start)",
            "- Length: \(Self.length(recording.seconds))",
            "- Audio: [\(audioFile)](\(audioFile.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? audioFile))",
            "- Pendant: \(recording.device)\(recording.firmware.map { ", firmware \($0)" } ?? "")",
        ]
        if let note = recording.clockNote { lines.append("- Clock: \(note)") }
        lines.append("- Imported: \(format("yyyy-MM-dd HH:mm", recording.importedAt))")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func length(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        if hours > 0 { return "\(hours) h \(minutes) min" }
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }
}

/// One recording as it was imported.
public struct Recording: Codable, Equatable, Identifiable {
    public var id: String { file }
    /// The audio file, relative to the import folder.
    public var file: String
    public var start: Date
    public var seconds: Double
    public var bytes: Int
    public var device: String
    public var firmware: String?
    /// Set when the start time was worked out or corrected rather than read.
    public var clockNote: String?
    public var importedAt: Date
    /// The records it was made from, so none is ever written twice.
    public var spans: [Span]?

    public struct Span: Codable, Equatable {
        public var journal: String
        public var first: UInt64
        public var last: UInt64

        public init(journal: String, first: UInt64, last: UInt64) {
            self.journal = journal
            self.first = first
            self.last = last
        }
    }

    public init(file: String, start: Date, seconds: Double, bytes: Int, device: String,
                firmware: String? = nil, clockNote: String? = nil, importedAt: Date = Date(),
                spans: [Span]? = nil) {
        self.file = file
        self.start = start
        self.seconds = seconds
        self.bytes = bytes
        self.device = device
        self.firmware = firmware
        self.clockNote = clockNote
        self.importedAt = importedAt
        self.spans = spans
    }
}

/// What has been imported, kept in the import folder itself so it travels
/// with the recordings (to another Mac, through a sync) and a second Mac
/// draining the same pendant knows what is already there.
public struct Ledger: Codable, Equatable {
    public var version = 1
    public var recordings: [Recording] = []

    public init() {}

    /// True when a record is already part of a finished recording.
    public func covers(journal: String, seq: UInt64) -> Bool {
        recordings.contains { $0.spans?.contains { $0.journal == journal && seq >= $0.first && seq <= $0.last } ?? false }
    }

    public static func load(from url: URL) -> Ledger {
        guard let data = try? Data(contentsOf: url) else { return Ledger() }
        return (try? decoder.decode(Ledger.self, from: data)) ?? Ledger()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
