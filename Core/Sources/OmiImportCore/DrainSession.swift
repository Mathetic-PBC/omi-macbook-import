import Foundation

/// Copies every unread record off the pendant into a journal, a window at a
/// time, telling the pendant to free each window only once it is on disk.
///
///     INFO → [ADVANCE to what is already saved] → READ window → DATA… → DONE
///          → save and sync → ADVANCE → INFO → … until read_seq == write_seq
///
/// Firmware 3.0.24 and later frees a record only when told (ADVANCE with the
/// ring's id). Earlier firmware (3.0.20–3.0.23) frees records itself as it
/// sends them, so for it the ADVANCE is a formality and a transfer cut short
/// loses what was in flight; nothing can be done about that from here.
///
/// Not thread-safe: call everything on one queue.
public final class DrainSession {
    public enum Event: Equatable {
        case info(RingInfo)
        /// Records copied so far this session, and how many there were to copy.
        case progress(done: Int, total: Int)
        /// Every record is copied: the pendant has nothing unread.
        case caughtUp(copied: Int)
        case failed(String)
    }

    private enum Phase: Equatable {
        case idle
        case awaitingInfo
        case awaitingBegin(start: UInt64)
        case reading(start: UInt64)
        case awaitingAdvance
        case finished
    }

    /// The official app reads 2700 records (about 1.2 MB) at a time.
    public static let window: UInt32 = 2700

    private let send: (Data) -> Void
    private let journalFor: (RingInfo) -> RecordJournal
    private let events: (Event) -> Void
    private let window: UInt32

    private var phase: Phase = .idle
    private var journal: RecordJournal?
    private var info: RingInfo?
    private var buffer = Data()
    private var pending: [PendantRecord] = []
    private var total = 0
    private var copied = 0
    private var emptyWindows = 0
    public private(set) var lastActivity = Date()

    public init(window: UInt32 = DrainSession.window,
                send: @escaping (Data) -> Void,
                journalFor: @escaping (RingInfo) -> RecordJournal,
                events: @escaping (Event) -> Void) {
        self.window = window
        self.send = send
        self.journalFor = journalFor
        self.events = events
    }

    public var isFinished: Bool { phase == .finished }

    /// Begins. The storage characteristic's notifications must already be on:
    /// the pendant drops replies it can't notify.
    public func start() {
        askForInfo()
    }

    private func askForInfo() {
        phase = .awaitingInfo
        lastActivity = Date()
        send(StorageCommand.info())
    }

    private func finish(_ event: Event) {
        phase = .finished
        events(event)
    }

    public func received(_ data: Data) {
        guard phase != .finished else { return }
        lastActivity = Date()
        let reply = StorageReply.parse(data)
        switch (phase, reply) {
        case (.awaitingInfo, .info(let info)):
            handle(info)

        case (.awaitingInfo, .ack(let status)):
            finish(.failed(status == StorageReply.notReady
                ? "The pendant's storage isn't ready. It will be tried again."
                : "The pendant refused to say what it has stored (code \(status))."))

        case (.awaitingBegin, .readBegin(let start, _)):
            buffer = Data()
            pending = []
            phase = .reading(start: start)

        case (.awaitingBegin, .ack(let status)):
            // 9: a transfer is already running (one left over from before);
            // 10: the start is no longer in the ring. Either way, start over.
            if status == StorageReply.notReady { send(StorageCommand.stop()) }
            askForInfo()

        case (.reading(let start), .data(let bytes)):
            buffer.append(bytes)
            let whole = buffer.count / PendantRecord.size
            if whole > 0 {
                for index in 0..<whole {
                    let range = (index * PendantRecord.size)..<((index + 1) * PendantRecord.size)
                    pending.append(PendantRecord(seq: start + UInt64(pending.count), bytes: buffer.subdata(in: range)))
                }
                buffer.removeSubrange(0..<(whole * PendantRecord.size))
                events(.progress(done: copied + pending.count, total: max(total, copied + pending.count)))
            }

        case (.reading(let start), .done(_, let next)):
            // The pendant says how far it got. If that isn't what arrived, a
            // notification went missing and the records after it are out of
            // step. Firmware that waits for confirmation still has them, so
            // the window is read again; older firmware has freed them, and
            // what did arrive whole is kept.
            let arrived = start + UInt64(pending.count)
            if (next != arrived || !buffer.isEmpty), info?.freesOnConfirmation == true {
                pending = []
                buffer = Data()
                emptyWindows += 1
                askForInfo()
            } else {
                saveWindow(start: start)
            }

        case (.awaitingAdvance, .ack):
            // 0: done. 10 on older firmware: it had freed them already.
            // 11: the ring was wiped meanwhile; INFO shows the new one.
            askForInfo()

        case (_, .liveMark), (_, .unknown):
            break

        default:
            break
        }
    }

    private func handle(_ info: RingInfo) {
        let first = self.info == nil
        self.info = info
        let journal = journal ?? journalFor(info)
        self.journal = journal
        if first {
            total = Int(info.unread)
            events(.info(info))
        }
        // Records already saved by an earlier run that the pendant was never
        // told about (the app stopped between saving and the ADVANCE).
        if info.freesOnConfirmation, let ring = info.ringID, let next = journal.nextSeq,
           next > info.readSeq, next <= info.writeSeq {
            phase = .awaitingAdvance
            send(StorageCommand.advance(ring: ring, to: next))
            return
        }
        guard info.unread > 0 else {
            finish(.caughtUp(copied: copied))
            return
        }
        guard emptyWindows < 3 else {
            finish(.failed("The pendant says it has audio but sent none. It will be tried again."))
            return
        }
        total = max(total, copied + Int(info.unread))
        let count = UInt32(min(UInt64(window), info.unread))
        phase = .awaitingBegin(start: info.readSeq)
        send(StorageCommand.read(from: info.readSeq, count: count))
    }

    /// Puts the window's records on disk, then lets the pendant free them.
    private func saveWindow(start: UInt64) {
        let records = pending
        pending = []
        buffer = Data()
        guard let journal, let info else { return }
        do {
            // Records with no audio aren't kept, but count as handled.
            let audible = records.filter { !$0.frames.isEmpty }
            try journal.append(audible)
            if let last = records.last { try journal.markHandled(through: last.seq) }
        } catch {
            finish(.failed("Couldn't save what the pendant sent: \(error.localizedDescription)"))
            return
        }
        copied += records.count
        emptyWindows = records.isEmpty ? emptyWindows + 1 : 0
        let next = start + UInt64(records.count)
        guard !records.isEmpty else {
            askForInfo()
            return
        }
        phase = .awaitingAdvance
        if let ring = info.ringID {
            send(StorageCommand.advance(ring: ring, to: next))
        } else {
            send(StorageCommand.advance(to: next))
        }
    }

    /// Called when nothing has come back for a while (the app's timer: 5 s
    /// for a reply, 15 s between DATA notifications).
    public func timedOut() {
        switch phase {
        case .reading(let start):
            // Keep what arrived; tell the pendant to stop; carry on from there.
            send(StorageCommand.stop())
            saveWindow(start: start)
        case .awaitingAdvance:
            // The pendant commits an ADVANCE before it answers; INFO shows
            // whether this one took.
            askForInfo()
        case .awaitingInfo, .awaitingBegin:
            finish(.failed("The pendant stopped answering. It will be tried again."))
        case .idle, .finished:
            break
        }
    }

    /// The connection dropped. What is in the journal stays; a window that
    /// was still arriving is saved as far as it got.
    public func connectionLost() {
        if case .reading = phase, !pending.isEmpty, let journal {
            try? journal.append(pending.filter { !$0.frames.isEmpty })
            if let last = pending.last { try? journal.markHandled(through: last.seq) }
        }
        pending = []
        phase = .finished
    }

    /// How long the current wait may last before `timedOut()`.
    public var patience: TimeInterval {
        if case .reading = phase { return 15 }
        return 5
    }
}
