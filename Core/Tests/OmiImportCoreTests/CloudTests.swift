import XCTest
@testable import OmiImportCore

/// Omi's conversations endpoint, as the backend behaves: newest first by
/// `created_at`, `end_date` inclusive, at most `limit` a page.
final class FakeCloud {
    var conversations: [CloudConversation] = []
    var requests: [(before: Date?, limit: Int)] = []
    /// Fail the nth request (counting from 1) with this error.
    var failures: [Int: CloudError] = [:]
    /// Answer the nth request with an empty, truncated page.
    var truncatedEmpty: Set<Int> = []

    func fetch(before: Date?, limit: Int) async throws -> CloudPage {
        requests.append((before, limit))
        if let failure = failures[requests.count] { throw failure }
        if truncatedEmpty.contains(requests.count) { return CloudPage(conversations: [], truncated: true) }
        let matching = conversations
            .filter { before == nil || $0.createdAt <= before! }
            .sorted { $0.createdAt > $1.createdAt }
        return CloudPage(conversations: Array(matching.prefix(limit)))
    }
}

final class CloudTests: XCTestCase {
    var folder: URL!
    var layout: RecordingLayout!
    let t0 = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18 11:06:40 UTC

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("omi-cloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        layout = RecordingLayout(folder: folder, timeZone: TimeZone(identifier: "UTC")!)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func conversation(_ n: Int, title: String? = nil, hoursAfter: Double? = nil) -> CloudConversation {
        let start = t0.addingTimeInterval((hoursAfter ?? Double(n)) * 3600)
        return CloudConversation(
            id: "conv_\(n)", createdAt: start, startedAt: start, finishedAt: start.addingTimeInterval(300),
            language: "en", source: "omi",
            structured: .init(title: title ?? "Talk \(n)", overview: "About thing \(n).", emoji: "💬", category: "personal",
                              actionItems: [.init(description: "Follow up on \(n)", completed: n % 2 == 0)]),
            transcriptSegments: [
                .init(text: "Hello there.", speakerID: 0, speakerName: "Hudson", start: 0, end: 1.5),
                .init(text: "How was it?", speakerID: 0, speakerName: "Hudson", start: 1.5, end: 3),
                .init(text: "Good.", speakerID: 1, speakerName: nil, start: 65, end: 66),
            ],
            folderName: nil, geolocation: nil)
    }

    func sync(pageSize: Int = 3, maxRequests: Int = 12) -> CloudSync {
        var sync = CloudSync(layout: layout)
        sync.pageSize = pageSize
        sync.maxRequests = maxRequests
        return sync
    }

    func notes() -> [String] {
        let days = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        return days.flatMap { day in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(day).path)) ?? []).sorted().map { "\(day)/\($0)" }
        }
    }

    // MARK: The API

    func testDecodesTheDocumentedResponse() throws {
        let json = """
        [{"id":"conv_202","created_at":"2025-01-20T13:50:00Z","started_at":"2025-01-20T13:50:00.250000+00:00",
          "finished_at":"2025-01-20T14:10:00","language":"en","source":"phone",
          "structured":{"title":"Feature Discussion","overview":"Brainstorming session for new features","emoji":"💼",
            "category":"business","action_items":[{"description":"Create mockups for new UI","completed":false,"due_at":null}],"events":[]},
          "transcript_segments":[{"id":"seg_001","text":"Let's discuss the new feature","speaker_id":0,"speaker_name":"John","start":0.0,"end":2.5},
            {"id":"seg_002","text":"I think we should focus on the user interface first","speaker_id":1,"speaker_name":"Speaker 1","start":2.5,"end":5.8}],
          "folder_id":"folder_uuid","folder_name":"Work","transcript_included":true,
          "geolocation":{"latitude":37.77,"longitude":-122.41,"address":"1 Market St, San Francisco, CA 94105, USA"}},
         {"id":"bare","created_at":"2025-01-21T00:00:00Z"}]
        """
        let parsed = try CloudAPI.decode(Data(json.utf8))
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].structured?.title, "Feature Discussion")
        XCTAssertEqual(parsed[0].transcriptSegments?.count, 2)
        XCTAssertEqual(parsed[0].startedAt?.timeIntervalSince1970 ?? 0, 1_737_381_000.25, accuracy: 0.001)
        // No zone given means UTC.
        XCTAssertEqual(parsed[0].finishedAt, CloudAPI.date("2025-01-20T14:10:00Z"))
        XCTAssertEqual(parsed[0].seconds, 1199.75, accuracy: 0.01)
        XCTAssertEqual(parsed[0].geolocation?.address, "1 Market St, San Francisco, CA 94105, USA")
        XCTAssertNil(parsed[1].structured)
        XCTAssertEqual(parsed[1].start, parsed[1].createdAt)
    }

    func testRequest() {
        let request = CloudAPI.request(key: "omi_dev_abc", before: Date(timeIntervalSince1970: 1_737_381_000.5), limit: 50)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.omi.me/v1/dev/user/conversations?include_transcript=true&limit=50&end_date=2025-01-20T13:50:00.500Z")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer omi_dev_abc")
        let first = CloudAPI.request(key: "k", before: nil, limit: 10)
        XCTAssertEqual(first.url?.query, "include_transcript=true&limit=10")
    }

    // MARK: Notes

    func testNote() {
        var one = conversation(1, title: "Lunch: plans / ideas")
        one.geolocation = .init(address: "UCSD")
        one.folderName = "Family"
        let note = layout.note(for: one)
        XCTAssertEqual(note, """
        # 💬 Lunch: plans / ideas

        - Started: 2026-11-18 12:06:40 +00:00
        - Length: 5 min
        - From: Omi's cloud, recorded on omi
        - Category: personal
        - Folder: Family
        - Place: UCSD
        - Omi conversation: conv_1

        About thing 1.

        ## Action items

        - [ ] Follow up on 1

        ## Transcript

        **Hudson** · 0:00
        Hello there. How was it?

        **Speaker 1** · 1:05
        Good.

        """)
        XCTAssertEqual(RecordingLayout.fileTitle("Lunch: plans / ideas"), "Lunch plans ideas")
        XCTAssertEqual(RecordingLayout.fileTitle(String(repeating: "word ", count: 30)).count, 59)
        XCTAssertEqual(RecordingLayout.clock(3725), "1:02:05")
    }

    // MARK: Syncing

    /// The first pass walks the whole history, a page at a time, and writes
    /// one note per conversation.
    func testFirstPassCopiesEverything() async throws {
        let cloud = FakeCloud()
        cloud.conversations = (0..<10).map { conversation($0) }
        let summary = try await sync().run(fetch: cloud.fetch)
        XCTAssertEqual(summary.added, 10)
        XCTAssertTrue(summary.historyComplete)
        XCTAssertEqual(notes().count, 10)
        XCTAssertEqual(notes().first, "2026-11-18/2026-11-18 11-06-40 Talk 0.md")
        XCTAssertEqual(notes().last, "2026-11-18/2026-11-18 20-06-40 Talk 9.md")
        // Pages of three, each starting at the oldest of the one before, then one that finds nothing older.
        XCTAssertNil(cloud.requests[0].before)
        XCTAssertEqual(cloud.requests.count, 6)
        let state = CloudState.load(from: layout.cloudStateURL)
        XCTAssertEqual(state.items.count, 10)
        XCTAssertEqual(state.newest, cloud.conversations[9].createdAt)
        XCTAssertNil(state.backfillBefore)
    }

    /// A later pass with nothing new asks once and writes nothing.
    func testNothingNewIsOneRequest() async throws {
        let cloud = FakeCloud()
        cloud.conversations = (0..<40).map { conversation($0) }
        try await sync(pageSize: 50).run(fetch: cloud.fetch)
        cloud.requests = []
        let summary = try await sync(pageSize: 50).run(fetch: cloud.fetch)
        XCTAssertEqual(summary, .init(added: 0, updated: 0, requests: 1, historyComplete: true))
        XCTAssertEqual(notes().count, 40)
    }

    /// New conversations are added; one whose title changed in the cloud is
    /// rewritten in the file it already has.
    func testNewAndChanged() async throws {
        let cloud = FakeCloud()
        cloud.conversations = (0..<5).map { conversation($0) }
        try await sync().run(fetch: cloud.fetch)

        cloud.conversations.append(conversation(5))
        cloud.conversations[4] = conversation(4, title: "Renamed")
        let summary = try await sync().run(fetch: cloud.fetch)
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.updated, 1)
        XCTAssertEqual(notes().count, 6)
        XCTAssertTrue(notes().contains("2026-11-18/2026-11-18 15-06-40 Talk 4.md"), "the file keeps its name")
        let text = try String(contentsOf: folder.appendingPathComponent("2026-11-18/2026-11-18 15-06-40 Talk 4.md"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# 💬 Renamed\n"))
    }

    /// A note the person wrote in is left alone, and one they deleted stays deleted.
    func testEditedAndDeletedNotesAreLeftAlone() async throws {
        let cloud = FakeCloud()
        cloud.conversations = (0..<3).map { conversation($0) }
        try await sync().run(fetch: cloud.fetch)
        let edited = folder.appendingPathComponent("2026-11-18/2026-11-18 13-06-40 Talk 2.md")
        let deleted = folder.appendingPathComponent("2026-11-18/2026-11-18 12-06-40 Talk 1.md")
        try Data("my own notes\n".utf8).write(to: edited)
        try FileManager.default.removeItem(at: deleted)

        cloud.conversations[2] = conversation(2, title: "Changed in the cloud")
        cloud.conversations[1] = conversation(1, title: "Also changed")
        let summary = try await sync().run(fetch: cloud.fetch)
        XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(try String(contentsOf: edited, encoding: .utf8), "my own notes\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleted.path))
    }

    /// The hourly allowance runs out partway through the history: the next
    /// pass carries on from there, and nothing is written twice.
    func testResumesAfterTheAllowanceRunsOut() async throws {
        let cloud = FakeCloud()
        cloud.conversations = (0..<10).map { conversation($0) }
        cloud.failures[3] = .rateLimited(retryAfter: 1800)
        do {
            try await sync().run(fetch: cloud.fetch)
            XCTFail("should have thrown")
        } catch let error as CloudError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 1800))
        }
        // Two pages of three; the second begins with the first's oldest.
        XCTAssertEqual(notes().count, 5)
        let state = CloudState.load(from: layout.cloudStateURL)
        XCTAssertFalse(state.historyComplete)
        XCTAssertNotNil(state.backfillBefore)

        cloud.failures = [:]
        let summary = try await sync().run(fetch: cloud.fetch)
        XCTAssertTrue(summary.historyComplete)
        XCTAssertEqual(notes().count, 10)
        XCTAssertEqual(Set(notes()).count, 10)
        XCTAssertEqual(CloudState.load(from: layout.cloudStateURL).items.count, 10)
    }

    /// A pass asks for no more than its share; the history is finished over
    /// several passes.
    func testAPassIsBounded() async throws {
        let cloud = FakeCloud()
        cloud.conversations = (0..<30).map { conversation($0, hoursAfter: Double($0) * 30) }
        var passes = 0
        var complete = false
        while !complete, passes < 10 {
            let before = cloud.requests.count
            let summary = try await sync(pageSize: 3, maxRequests: 4).run(fetch: cloud.fetch)
            XCTAssertLessThanOrEqual(cloud.requests.count - before, 4)
            complete = summary.historyComplete
            passes += 1
        }
        XCTAssertTrue(complete)
        XCTAssertGreaterThan(passes, 2)
        XCTAssertEqual(notes().count, 30)
    }

    /// An empty page marked truncated is the server stopping early, not the
    /// end of the history.
    func testATruncatedEmptyPageIsNotTheEnd() async throws {
        let cloud = FakeCloud()
        cloud.conversations = (0..<5).map { conversation($0) }
        cloud.truncatedEmpty = [2]
        let summary = try await sync().run(fetch: cloud.fetch)
        XCTAssertEqual(cloud.requests[2].limit, 2, "the page after a truncated one asks for less")
        XCTAssertEqual(summary.added, 5)
        XCTAssertTrue(summary.historyComplete)
    }

    /// More conversations made in one instant than fit a page don't stop the walk.
    func testManyInOneInstant() async throws {
        let cloud = FakeCloud()
        cloud.conversations = (0..<4).map { conversation($0) }
        for n in 10..<15 {
            var same = conversation(n, hoursAfter: 2)
            same.startedAt = same.createdAt.addingTimeInterval(Double(n))
            cloud.conversations.append(same)
        }
        let summary = try await sync(pageSize: 2).run(fetch: cloud.fetch)
        XCTAssertTrue(summary.historyComplete)
        // The API can't page through what shares an instant; what matters is
        // that the walk gets past it to everything older.
        XCTAssertTrue(notes().contains("2026-11-18/2026-11-18 11-06-40 Talk 0.md"))
        XCTAssertTrue(notes().contains("2026-11-18/2026-11-18 12-06-40 Talk 1.md"))
    }

    /// Two conversations that began in the same second with the same title
    /// get different files.
    func testSameSecondSameTitle() async throws {
        let cloud = FakeCloud()
        var twin = conversation(1)
        twin.id = "conv_twin"
        twin.createdAt = twin.createdAt.addingTimeInterval(0.4)
        cloud.conversations = [conversation(1), twin]
        try await sync().run(fetch: cloud.fetch)
        XCTAssertEqual(notes(), ["2026-11-18/2026-11-18 12-06-40 2 Talk 1.md", "2026-11-18/2026-11-18 12-06-40 Talk 1.md"])
    }
}
