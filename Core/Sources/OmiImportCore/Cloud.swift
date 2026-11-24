import Foundation

/// What the Omi app has already taken off the pendant lives in Omi's cloud as
/// conversations: a title, a summary and a transcript with speakers. The
/// Developer API (docs/doc/developer/api in BasedHardware/omi) hands those
/// out, to a key made at app.omi.me/developers with `conversations:read`.
/// It does not hand out audio, so a cloud conversation becomes a markdown
/// note and nothing else.
public struct CloudConversation: Decodable, Equatable {
    public var id: String
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var language: String?
    public var source: String?
    public var structured: Structured?
    public var transcriptSegments: [Segment]?
    public var folderName: String?
    public var geolocation: Geolocation?

    public struct Structured: Decodable, Equatable {
        public var title: String?
        public var overview: String?
        public var emoji: String?
        public var category: String?
        public var actionItems: [ActionItem]?

        enum CodingKeys: String, CodingKey {
            case title, overview, emoji, category
            case actionItems = "action_items"
        }
    }

    public struct ActionItem: Decodable, Equatable {
        public var description: String
        public var completed: Bool?
    }

    public struct Segment: Decodable, Equatable {
        public var text: String
        public var speakerID: Int?
        public var speakerName: String?
        public var start: Double?
        public var end: Double?

        enum CodingKeys: String, CodingKey {
            case text, start, end
            case speakerID = "speaker_id"
            case speakerName = "speaker_name"
        }
    }

    public struct Geolocation: Decodable, Equatable {
        public var address: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, language, source, structured, geolocation
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case transcriptSegments = "transcript_segments"
        case folderName = "folder_name"
    }

    /// When it began: the recording's start, else when the record was made.
    public var start: Date { startedAt ?? createdAt }

    public var seconds: Double {
        if let finishedAt, finishedAt > start { return finishedAt.timeIntervalSince(start) }
        return transcriptSegments?.compactMap(\.end).max() ?? 0
    }
}

public enum CloudAPI {
    public static let base = URL(string: "https://api.omi.me/v1/dev")!

    /// A page of conversations with their transcripts, newest first, made no
    /// later than `before`. The API orders by `created_at`, newest first, and
    /// both date bounds are inclusive (backend `get_conversations_without_photos`).
    public static func request(base: URL = CloudAPI.base, key: String, before: Date?, limit: Int) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent("user/conversations"), resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "include_transcript", value: "true"),
                     URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "end_date", value: format(before))) }
        components.queryItems = query
        // A literal + in a query reads as a space on the server.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("omi-macbook-import", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        return request
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// The API's dates: ISO 8601, with or without fractions of a second, and
    /// UTC when no zone is given.
    public static func date(_ text: String) -> Date? {
        var text = text
        let zoned = text.hasSuffix("Z") || text.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) != nil
        if !zoned { text += "Z" }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: text)
    }

    public static func decode(_ data: Data) throws -> [CloudConversation] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = CloudAPI.date(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
            }
            return date
        }
        return try decoder.decode([CloudConversation].self, from: data)
    }
}

public struct CloudPage {
    public var conversations: [CloudConversation]
    /// The server stopped short of a full page: what is here is not all there is.
    public var truncated: Bool

    public init(conversations: [CloudConversation], truncated: Bool = false) {
        self.conversations = conversations
        self.truncated = truncated
    }
}

public enum CloudError: Error, Equatable {
    /// The key is wrong or was deleted.
    case unauthorized
    /// The key is fine but may not read conversations.
    case forbidden
    /// Too many requests; try again after this many seconds.
    case rateLimited(retryAfter: TimeInterval)
    case server(Int)
    case offline(String)
}

/// What has been copied from the cloud, kept beside the ledger.
public struct CloudState: Codable, Equatable {
    public struct Item: Codable, Equatable {
        /// The note, relative to the import folder.
        public var file: String
        public var start: Date
        public var seconds: Double
        public var title: String
        /// A fingerprint of the note's text, to tell when the cloud's copy changed.
        public var digest: String
    }

    public var items: [String: Item] = [:]
    /// The newest conversation seen, by when its record was made.
    public var newest: Date?
    /// Every conversation older than this is still to be fetched; nil before
    /// the first pass.
    public var backfillBefore: Date?
    /// The whole history has been walked once.
    public var historyComplete = false

    public init() {}

    public static func load(from url: URL) -> CloudState {
        guard let data = try? Data(contentsOf: url) else { return CloudState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode(CloudState.self, from: data)) ?? CloudState()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension RecordingLayout {
    public var cloudStateURL: URL { stateFolder.appendingPathComponent("cloud.json") }

    /// The note for a cloud conversation. Segments by the same speaker that
    /// follow one another are one paragraph.
    public func note(for conversation: CloudConversation) -> String {
        let structured = conversation.structured
        let title = Self.clean(structured?.title) ?? "Untitled"
        var lines = ["# \([structured?.emoji, title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " "))", ""]
        lines.append("- Started: \(stamp(conversation.start))")
        if conversation.seconds > 0 { lines.append("- Length: \(Self.length(conversation.seconds))") }
        lines.append("- From: Omi's cloud\(conversation.source.map { ", recorded on \($0)" } ?? "")")
        if let category = Self.clean(structured?.category) { lines.append("- Category: \(category)") }
        if let folder = Self.clean(conversation.folderName) { lines.append("- Folder: \(folder)") }
        if let place = Self.clean(conversation.geolocation?.address) { lines.append("- Place: \(place)") }
        lines.append("- Omi conversation: \(conversation.id)")
        if let overview = Self.clean(structured?.overview) { lines += ["", overview] }
        if let items = structured?.actionItems, !items.isEmpty {
            lines += ["", "## Action items", ""]
            lines += items.map { "- [\($0.completed == true ? "x" : " ")] \($0.description)" }
        }
        let segments = (conversation.transcriptSegments ?? []).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !segments.isEmpty {
            lines += ["", "## Transcript"]
            var speaker: String?
            for segment in segments {
                let name = Self.clean(segment.speakerName) ?? segment.speakerID.map { "Speaker \($0)" } ?? "Speaker"
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if name == speaker {
                    lines[lines.count - 1] += " " + text
                } else {
                    lines += ["", "**\(name)** · \(Self.clock(segment.start ?? 0))", text]
                    speaker = name
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss xxx"
        return formatter.string(from: date)
    }

    static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Seconds into a conversation as m:ss, or h:mm:ss.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// A title as part of a file name: no slashes, colons or control
    /// characters, and not too long.
    static func fileTitle(_ title: String) -> String {
        let banned = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters).union(.newlines)
        let kept = title.unicodeScalars.map { banned.contains($0) ? " " : String($0) }.joined()
        let words = kept.split(separator: " ").joined(separator: " ")
        let trimmed = String(words.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed
    }
}

/// Copies conversations from the cloud into the import folder: one note
/// each, in the folder for its day, named for when it began and its title.
/// A conversation already copied is written again, in the same file, only
/// when the cloud's copy has changed and the note is still as it was written.
public struct CloudSync {
    public struct Summary: Equatable {
        public var added = 0
        public var updated = 0
        public var requests = 0
        /// The walk back through history is finished.
        public var historyComplete = false
    }

    public let layout: RecordingLayout
    /// How far back a regular pass looks again. A conversation shows up once
    /// it has been processed, under the time it began, and its summary and
    /// speaker names can change for a while after.
    public var lookBack: TimeInterval = 24 * 3600
    public var pageSize = 50
    /// At most this many requests a pass: the API allows 25 transcript
    /// requests an hour.
    public var maxRequests = 12

    public init(layout: RecordingLayout) {
        self.layout = layout
    }

    public typealias Fetch = (_ before: Date?, _ limit: Int) async throws -> CloudPage

    /// One pass: what is new since last time, then more of the history if
    /// the first walk through it isn't finished. State is saved after every
    /// page, so a pass cut short (no network, the hourly allowance used up)
    /// is carried on by the next.
    @discardableResult
    public func run(fetch: Fetch) async throws -> Summary {
        var state = CloudState.load(from: layout.cloudStateURL)
        var summary = Summary()

        // What is new, back to a day before the newest one seen.
        if let newest = state.newest {
            try await walk(from: nil, downTo: newest.addingTimeInterval(-lookBack), state: &state, summary: &summary, fetch: fetch) { _, _ in }
        }
        // The history, from where the last pass stopped.
        if !state.historyComplete, summary.requests < maxRequests {
            let finished = try await walk(from: state.backfillBefore, downTo: nil, state: &state, summary: &summary, fetch: fetch) { state, cursor in
                state.backfillBefore = cursor
            }
            if finished {
                state.historyComplete = true
                state.backfillBefore = nil
                try state.save(to: layout.cloudStateURL)
            }
        }
        summary.historyComplete = state.historyComplete
        return summary
    }

    /// Walks pages from `from` (nil: now) towards the past, until a page
    /// reaches `downTo`, or there is nothing older. Returns false when it
    /// stopped for the request limit instead.
    @discardableResult
    private func walk(from: Date?, downTo: Date?, state: inout CloudState, summary: inout Summary, fetch: Fetch,
                      moved: (inout CloudState, Date) -> Void) async throws -> Bool {
        var cursor = from
        var seen: Set<String> = []
        var limit = max(2, pageSize)
        var askedForLess = false
        while true {
            guard summary.requests < maxRequests else { return false }
            let page = try await fetch(cursor, limit)
            summary.requests += 1
            let fresh = page.conversations.filter { !seen.contains($0.id) }
            if fresh.isEmpty {
                // Nothing older. A truncated empty page is the server giving
                // up early, not the end: ask for less, once.
                if page.truncated, !askedForLess {
                    askedForLess = true
                    limit = max(2, min(10, limit / 2))
                    continue
                }
                // A full page of ones already seen: they were all made in
                // the same instant as the last page's oldest. Step past it.
                if page.conversations.count >= limit, let oldest = page.conversations.map(\.createdAt).min() {
                    cursor = oldest.addingTimeInterval(-0.001)
                    continue
                }
                return !page.truncated
            }
            askedForLess = false
            for conversation in fresh {
                seen.insert(conversation.id)
                switch try store(conversation, state: &state) {
                case .added: summary.added += 1
                case .updated: summary.updated += 1
                case .unchanged: break
                }
                state.newest = max(state.newest ?? conversation.createdAt, conversation.createdAt)
            }
            let oldest = fresh.map(\.createdAt).min()!
            // The bound is inclusive and dates are read to the millisecond:
            // a hair later keeps the oldest one in the next page, where it is
            // recognised, rather than risk skipping one made in the same instant.
            cursor = oldest.addingTimeInterval(0.001)
            moved(&state, cursor!)
            try state.save(to: layout.cloudStateURL)
            if let downTo, oldest < downTo { return true }
        }
    }

    enum Change { case added, updated, unchanged }

    private func store(_ conversation: CloudConversation, state: inout CloudState) throws -> Change {
        let text = layout.note(for: conversation)
        let digest = Self.digest(text)
        let title = RecordingLayout.clean(conversation.structured?.title) ?? "Untitled"
        let manager = FileManager.default

        if var item = state.items[conversation.id] {
            let url = layout.folder.appendingPathComponent(item.file)
            // Still the same: leave it. A note the person deleted is not
            // brought back, and one they have written in is not overwritten.
            guard item.digest != digest, let onDisk = try? String(contentsOf: url, encoding: .utf8),
                  Self.digest(onDisk) == item.digest else { return .unchanged }
            try Data(text.utf8).write(to: url, options: .atomic)
            item.digest = digest
            item.title = title
            item.seconds = conversation.seconds
            state.items[conversation.id] = item
            return .updated
        }

        let day = layout.dayFolder(for: conversation.start)
        try manager.createDirectory(at: day, withIntermediateDirectories: true)
        let suffix = RecordingLayout.fileTitle(title)
        let base = layout.baseName(for: conversation.start) { name in
            let full = suffix.isEmpty ? name : "\(name) \(suffix)"
            return manager.fileExists(atPath: day.appendingPathComponent("\(full).md").path)
        }
        let name = suffix.isEmpty ? base : "\(base) \(suffix)"
        try Data(text.utf8).write(to: day.appendingPathComponent("\(name).md"), options: .atomic)
        state.items[conversation.id] = .init(file: "\(day.lastPathComponent)/\(name).md", start: conversation.start,
                                              seconds: conversation.seconds, title: title, digest: digest)
        return .added
    }

    /// FNV-1a, 64 bits: enough to tell two versions of a note apart.
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
