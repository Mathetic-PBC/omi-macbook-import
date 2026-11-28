import CryptoKit
import Foundation
import Network

/// How a phone gives a finished recording to the Mac that keeps it.
///
/// The Mac listens on one port and says so over Bonjour. The phone connects,
/// and for each recording:
///
///     phone → Mac   offer    what it is: when, how long, how big, its SHA-256
///     Mac → phone   answer   send it, or "I have that one"
///     phone → Mac   the file's bytes
///     Mac → phone   receipt  stored, or why not
///
/// The phone deletes its copy only on a receipt or an "I have that one", so a
/// recording is always in at least one place. Offer, answer and receipt are
/// JSON behind a four-byte big-endian length.
///
/// The connection is TLS with a key both sides derive from the pairing code,
/// so a device without the code can neither send nor listen in, and nothing
/// passes through anyone else's server.
public enum Handoff {
    public static let serviceType = "_omi-import._tcp"
    public static let port: UInt16 = 47843
    static let chunk = 256 * 1024
    static let largestFrame = 64 * 1024
    static let largestFile = 4 << 30
    /// A connection with nothing moving on it for this long is dropped.
    static let patience: TimeInterval = 30
}

public struct HandoffOffer: Codable, Equatable {
    public var version = 1
    public var start: Date
    public var seconds: Double
    public var bytes: Int
    public var sha256: String
    public var device: String
    public var firmware: String?
    public var clockNote: String?

    public init(start: Date, seconds: Double, bytes: Int, sha256: String, device: String,
                firmware: String? = nil, clockNote: String? = nil) {
        self.start = start
        self.seconds = seconds
        self.bytes = bytes
        self.sha256 = sha256
        self.device = device
        self.firmware = firmware
        self.clockNote = clockNote
    }
}

struct HandoffAnswer: Codable {
    var want: Bool
    /// Where the Mac already has it, when it doesn't want it.
    var file: String?
}

struct HandoffReceipt: Codable {
    var stored: Bool
    var file: String?
    var error: String?
}

public enum HandoffError: Error, Equatable {
    /// The two sides derive different keys: the pairing code is wrong.
    case wrongCode
    case unreachable(String)
    case closed
    /// The Mac got it and wouldn't keep it.
    case refused(String)
    case malformed
}

// MARK: - The pairing code

/// The code typed into the phone once. Twenty characters, 100 bits, from an
/// alphabet with no letters that read as digits.
public enum Pairing {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let length = 20

    public static func newCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// The code as typed, tidied: any case, with or without dashes, I and L
    /// for 1, O for 0. Nil when it isn't a whole code.
    public static func normalize(_ typed: String) -> String? {
        var out = ""
        for character in typed.uppercased() {
            switch character {
            case "I", "L": out.append("1")
            case "O": out.append("0")
            case _ where alphabet.contains(character): out.append(character)
            case "-", " ", "\n": continue
            default: return nil
            }
        }
        return out.count == length ? out : nil
    }

    /// In fives, for reading across a room.
    public static func display(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 5).map { offset -> String in
            let start = code.index(code.startIndex, offsetBy: offset)
            return String(code[start..<(code.index(start, offsetBy: 5, limitedBy: code.endIndex) ?? code.endIndex)])
        }.joined(separator: "-")
    }
}

extension NWParameters {
    /// TLS keyed by the pairing code, over TCP.
    public static func handoff(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let mac = HMAC<SHA256>.authenticationCode(for: Data("omi-import handoff v1".utf8),
                                                  using: SymmetricKey(data: Data(code.utf8)))
        let key = Data(mac).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("omi-import".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
}

// MARK: - The connection

/// One connection, read and written a whole message at a time.
final class Wire {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var watchdog: DispatchWorkItem?
    private var failure: NWError?

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting(let error), .failed(let error):
                // No waiting for a network that may come back: the phone
                // tries again by itself.
                self?.failure = self?.failure ?? error
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        touch()
    }

    func close() {
        queue.async {
            self.watchdog?.cancel()
            self.connection.cancel()
        }
    }

    private func touch() {
        queue.async {
            self.watchdog?.cancel()
            let item = DispatchWorkItem { [connection = self.connection] in connection.cancel() }
            self.watchdog = item
            self.queue.asyncAfter(deadline: .now() + Handoff.patience, execute: item)
        }
    }

    private func problem(_ error: NWError?) -> HandoffError {
        switch failure ?? error {
        case .tls?: return .wrongCode
        case let other?: return .unreachable("\(other)")
        case nil: return .closed
        }
    }

    func read(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        touch()
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: self.problem(error))
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        touch()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: self.problem(error)) } else { continuation.resume() }
            })
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    func send<Message: Encodable>(_ message: Message) async throws {
        let body = try Self.encoder.encode(message)
        var frame = Data()
        frame.appendBE(UInt32(body.count))
        frame.append(body)
        try await write(frame)
    }

    func receive<Message: Decodable>(_ type: Message.Type) async throws -> Message {
        let length = Int([UInt8](try await read(4)).be32(0))
        guard length > 0, length <= Handoff.largestFrame else { throw HandoffError.malformed }
        do {
            return try Self.decoder.decode(type, from: try await read(length))
        } catch is DecodingError {
            throw HandoffError.malformed
        }
    }
}

public enum FileDigest {
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: Handoff.chunk), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().hex
    }
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - The Mac's side

/// Puts what a phone sends into the import folder: the audio, a note beside
/// it, and a line in the ledger. One recording at a time.
public actor HandoffStore {
    public let layout: RecordingLayout

    public init(layout: RecordingLayout) {
        self.layout = layout
    }

    /// Where this recording already is, if it was taken before. A recording
    /// deleted from the folder since still counts: it is not asked for again.
    public func held(_ offer: HandoffOffer) -> String? {
        Ledger.load(from: layout.ledgerURL).recordings.first { $0.digest == offer.sha256 }?.file
    }

    /// Clears what a transfer cut short left behind.
    public func sweep() {
        try? FileManager.default.removeItem(at: layout.incomingFolder)
    }

    func temporary() throws -> URL {
        try FileManager.default.createDirectory(at: layout.incomingFolder, withIntermediateDirectories: true)
        let url = layout.incomingFolder.appendingPathComponent("\(UUID().uuidString).opus")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw HandoffError.refused("The Mac couldn't write to the import folder.")
        }
        return url
    }

    /// Takes a file that arrived whole. Throws, and removes it, when it
    /// isn't what the offer said.
    public func place(_ offer: HandoffOffer, temporary: URL, digest: String, now: Date = Date()) throws -> Recording {
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: temporary.path))?[.size] as? Int ?? -1
        guard digest == offer.sha256, size == offer.bytes else {
            try? manager.removeItem(at: temporary)
            throw HandoffError.refused("The recording didn't arrive whole.")
        }
        var ledger = Ledger.load(from: layout.ledgerURL)
        if let existing = ledger.recordings.first(where: { $0.digest == digest }) {
            try? manager.removeItem(at: temporary)
            return existing
        }
        let day = layout.dayFolder(for: offer.start)
        try manager.createDirectory(at: day, withIntermediateDirectories: true)
        let base = layout.baseName(for: offer.start) { name in
            manager.fileExists(atPath: day.appendingPathComponent("\(name).opus").path)
                || manager.fileExists(atPath: day.appendingPathComponent("\(name).md").path)
        }
        let audio = day.appendingPathComponent("\(base).opus")
        try manager.moveItem(at: temporary, to: audio)
        let recording = Recording(file: "\(day.lastPathComponent)/\(audio.lastPathComponent)", start: offer.start,
                                  seconds: offer.seconds, bytes: size, device: offer.device, firmware: offer.firmware,
                                  clockNote: offer.clockNote, importedAt: now, digest: digest)
        try Data(layout.note(for: recording, audioFile: audio.lastPathComponent).utf8)
            .write(to: day.appendingPathComponent("\(base).md"), options: .atomic)
        ledger.recordings.append(recording)
        try ledger.save(to: layout.ledgerURL)
        return recording
    }
}

/// The Mac listening for phones.
public final class HandoffServer {
    public enum Event {
        /// Listening, on this port.
        case ready(UInt16)
        case failed(String)
        case receiving(done: Int, total: Int)
        case stored(Recording)
        /// A transfer ended early or was turned away.
        case problem(String)
    }

    private let queue = DispatchQueue(label: "com.mathetic.OmiImport.handoff")
    private let store: HandoffStore
    private let code: String
    private let port: UInt16
    private let advertise: Bool
    private let events: (Event) -> Void
    private var listener: NWListener?

    /// `port` 0 takes any free port; `advertise` puts the Mac on Bonjour.
    public init(layout: RecordingLayout, code: String, port: UInt16 = Handoff.port, advertise: Bool = true,
                events: @escaping (Event) -> Void) {
        self.store = HandoffStore(layout: layout)
        self.code = code
        self.port = port
        self.advertise = advertise
        self.events = events
    }

    public func start() throws {
        let listener = try NWListener(using: .handoff(code: code),
                                      on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        if advertise { listener.service = NWListener.Service(type: Handoff.serviceType) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready: self?.events(.ready(listener?.port?.rawValue ?? 0))
            case .failed(let error): self?.events(.failed("\(error)"))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let wire = Wire(connection, queue: self.queue)
            Task { await self.serve(wire) }
        }
        self.listener = listener
        Task {
            await store.sweep()
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ wire: Wire) async {
        defer { wire.close() }
        do {
            while true {
                let offer = try await wire.receive(HandoffOffer.self)
                guard offer.bytes > 0, offer.bytes <= Handoff.largestFile else { throw HandoffError.malformed }
                if let file = await store.held(offer) {
                    try await wire.send(HandoffAnswer(want: false, file: file))
                    continue
                }
                let temporary = try await store.temporary()
                do {
                    try await wire.send(HandoffAnswer(want: true))
                    let digest = try await take(offer, into: temporary, from: wire)
                    let recording = try await store.place(offer, temporary: temporary, digest: digest)
                    try await wire.send(HandoffReceipt(stored: true, file: recording.file))
                    events(.stored(recording))
                } catch HandoffError.refused(let why) {
                    events(.problem(why))
                    try await wire.send(HandoffReceipt(stored: false, error: why))
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    throw error
                }
            }
        } catch HandoffError.closed {
            // The phone is done.
        } catch HandoffError.wrongCode {
            events(.problem("A phone tried to connect with a different pairing code."))
        } catch {
            events(.problem("A transfer ended early: \(error)"))
        }
    }

    private func take(_ offer: HandoffOffer, into url: URL, from wire: Wire) async throws -> String {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var done = 0
        while done < offer.bytes {
            let chunk = try await wire.read(min(Handoff.chunk, offer.bytes - done))
            do { try handle.write(contentsOf: chunk) } catch {
                throw HandoffError.refused("The Mac couldn't write to the import folder: \(error.localizedDescription)")
            }
            hasher.update(data: chunk)
            done += chunk.count
            events(.receiving(done: done, total: offer.bytes))
        }
        // On disk before the phone is told it may let go of its copy.
        try handle.synchronize()
        return hasher.finalize().hex
    }
}

// MARK: - The phone's side

public enum HandoffClient {
    public struct Item {
        public var offer: HandoffOffer
        public var url: URL

        public init(offer: HandoffOffer, url: URL) {
            self.offer = offer
            self.url = url
        }

        /// A finished recording in the phone's own folder, measured.
        public init(_ recording: Recording, in folder: URL) throws {
            let url = folder.appendingPathComponent(recording.file)
            let bytes = (try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? Int ?? 0
            self.init(offer: HandoffOffer(start: recording.start, seconds: recording.seconds, bytes: bytes,
                                          sha256: try FileDigest.sha256(of: url), device: recording.device,
                                          firmware: recording.firmware, clockNote: recording.clockNote),
                      url: url)
        }
    }

    /// Gives each recording to the Mac in turn. `delivered` is called as
    /// each one is safely there, with where the Mac put it; an error stops
    /// at the first one that wasn't.
    public static func send(_ items: [Item], to endpoint: NWEndpoint, code: String,
                            delivered: (Item, String) -> Void) async throws {
        let wire = Wire(NWConnection(to: endpoint, using: .handoff(code: code)),
                        queue: DispatchQueue(label: "com.mathetic.OmiImport.handoff.client"))
        defer { wire.close() }
        for item in items {
            try await wire.send(item.offer)
            let answer = try await wire.receive(HandoffAnswer.self)
            if !answer.want {
                delivered(item, answer.file ?? "")
                continue
            }
            let handle = try FileHandle(forReadingFrom: item.url)
            defer { try? handle.close() }
            var left = item.offer.bytes
            while left > 0 {
                guard let chunk = try handle.read(upToCount: min(Handoff.chunk, left)), !chunk.isEmpty else {
                    throw HandoffError.malformed
                }
                try await wire.write(chunk)
                left -= chunk.count
            }
            let receipt = try await wire.receive(HandoffReceipt.self)
            guard receipt.stored else { throw HandoffError.refused(receipt.error ?? "The Mac didn't keep it.") }
            delivered(item, receipt.file ?? "")
        }
    }
}
