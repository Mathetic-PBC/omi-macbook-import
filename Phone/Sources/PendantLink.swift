import CoreBluetooth
import Foundation
import OmiImportCore

/// The pendant's Bluetooth services (firmware `transport.c`, `storage.c`).
enum OmiGATT {
    private static func omi(_ short: String) -> CBUUID { CBUUID(string: "\(short)-E8F2-537E-4F6C-D104768A1214") }

    static let audioService = omi("19B10000")
    /// Live audio: `[index u16 LE][fragment u8][Opus bytes]`.
    static let audioData = omi("19B10001")
    static let storageService = CBUUID(string: "30295780-4301-EABD-2904-2849ADFEAE43")
    /// Commands in (write with response), every reply out (notify).
    static let storageData = CBUUID(string: "30295781-4301-EABD-2904-2849ADFEAE43")
    static let timeService = omi("19B10030")
    /// Write: u32 little-endian seconds since 1970.
    static let timeWrite = omi("19B10031")
    /// Read: the same; 0 when the clock was never set.
    static let timeRead = omi("19B10032")
    static let deviceInformation = CBUUID(string: "180A")
    static let firmwareRevision = CBUUID(string: "2A26")
    static let batteryService = CBUUID(string: "180F")
    /// One byte, a percentage. The pendant sends it every five seconds while
    /// connected, which is also what keeps this app awake in the background.
    static let batteryLevel = CBUUID(string: "2A19")

    static let services = [audioService, storageService, timeService, deviceInformation, batteryService]
}

/// The Bluetooth side: finding the pendant, staying connected to it, and
/// taking its audio.
///
/// A phone is carried with the pendant, so unlike a Mac it stays connected.
/// What the pendant stored while the phone was away is copied when it
/// connects, and asked for again every few minutes. In between:
///
/// - Firmware before 3.0.24 stores nothing while something is connected, so
///   it is listened to live and what is heard is kept.
/// - Firmware from 3.0.24 stores while connected, so it is not listened to:
///   everything comes from its storage, which it frees only when told.
///
/// iOS suspends an app in the background until Bluetooth has something for
/// it. The pendant reports its battery every five seconds, so while it is
/// connected the app runs often enough to finish recordings and send them.
/// iOS keeps a connection request open until the pendant is in range and
/// starts the app again for it, so nothing here scans once a pendant is known.
///
/// Everything here runs on `queue`; the app is told on the main queue.
final class PendantLink: NSObject {
    /// How often what the pendant has stored is asked for while connected.
    static let interval: TimeInterval = 5 * 60
    private static let retry: TimeInterval = 60
    private static let restoreKey = "com.mathetic.OmiRelay.pendant"

    private let queue = DispatchQueue(label: "com.mathetic.OmiRelay.pendant")
    private weak var relay: Relay?
    private let layout: RecordingLayout
    private var central: CBCentralManager!
    private var timer: DispatchSourceTimer?
    private var savedPendant: UUID?

    // The connection.
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var firmware: String?
    private var connecting = false
    private var nextCheck: Date?
    private var connectedAt: Date?
    private var battery: Int?

    // One copy.
    private var session: DrainSession?
    private var storageNotifying = false
    private var clockRead = false
    private var preflightDeadline: Date?
    /// The pendant's clock, and how far it was from this phone's, read on connecting.
    private var pendantEpoch: UInt32 = 0
    private var drift: TimeInterval = 0
    private var ringKey: String?
    /// The copy is over; the next one starts at `nextCheck`.
    private var copyDone = false

    // Live audio.
    private var packer = LivePacker()
    private var liveBuffer: [Data] = []
    private var liveOn = false
    private var lastLiveIndex: UInt16?
    private var liveLost = 0
    private var liveHeard = 0
    private var lastLiveFlush = Date()
    private var lastAssemble = Date()

    init(relay: Relay, layout: RecordingLayout) {
        self.relay = relay
        self.layout = layout
        super.init()
    }

    // MARK: From the app (any queue)

    func start(pendant: UUID?) {
        queue.async {
            self.savedPendant = pendant
            self.central = CBCentralManager(delegate: self, queue: self.queue, options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                // Lets iOS start the app again for the pendant after closing it.
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreKey,
            ])
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Ask the pendant what it has now.
    func copyNow() {
        queue.async {
            self.nextCheck = Date()
            if self.peripheral == nil { self.connectOrScan() } else { self.connectNow() }
        }
    }

    func forget() {
        queue.async {
            if let peripheral = self.peripheral { self.central.cancelPeripheralConnection(peripheral) }
            self.endConnection()
            self.peripheral = nil
            self.savedPendant = nil
            self.connecting = false
            self.characteristics = [:]
            self.queue.asyncAfter(deadline: .now() + 1) { self.connectOrScan() }
        }
    }

    // MARK: Telling the app

    private func status(_ text: String) {
        DispatchQueue.main.async { self.relay?.setPendantStatus(text) }
    }

    private func progress(_ value: Double?) {
        DispatchQueue.main.async { self.relay?.setProgress(value) }
    }

    private var name: String { peripheral?.name ?? "your pendant" }

    /// A name for this pendant in file names: the start of the identifier
    /// iOS gives it, which is the same every time on this phone.
    private var tag: String {
        String((peripheral?.identifier.uuidString ?? "pendant").prefix(8)).lowercased()
    }

    // MARK: Connecting

    private func connectOrScan() {
        guard central?.state == .poweredOn else { return }
        if let peripheral {
            attach(peripheral)
            return
        }
        if let saved = savedPendant, let known = central.retrievePeripherals(withIdentifiers: [saved]).first {
            attach(known)
            return
        }
        // Not met before. A pendant another app on this phone is connected
        // to doesn't advertise, but iOS can hand it over.
        if let connected = central.retrieveConnectedPeripherals(withServices: [OmiGATT.audioService]).first {
            remember(connected)
            attach(connected)
            return
        }
        status("Looking for your pendant")
        central.scanForPeripherals(withServices: [OmiGATT.audioService], options: nil)
    }

    private func remember(_ found: CBPeripheral) {
        savedPendant = found.identifier
        let identifier = found.identifier, name = found.name ?? "Omi"
        DispatchQueue.main.async { self.relay?.remember(pendant: identifier, name: name) }
    }

    private func attach(_ found: CBPeripheral) {
        peripheral = found
        found.delegate = self
        if found.state == .connected {
            // Already connected: iOS kept the connection while the app was closed.
            connected(found)
        } else {
            connectNow()
        }
    }

    private func connectNow() {
        guard let peripheral, central.state == .poweredOn else { return }
        guard peripheral.state == .disconnected, !connecting else { return }
        connecting = true
        status("Waiting for \(name) to come into range")
        central.connect(peripheral, options: nil)
    }

    private func connected(_ peripheral: CBPeripheral) {
        connecting = false
        copyDone = false
        storageNotifying = false
        characteristics = [:]
        status("Connected to \(name)")
        peripheral.discoverServices(OmiGATT.services)
    }

    // MARK: One copy

    /// Services are known. Listen first, then ask.
    private func begin(on peripheral: CBPeripheral) {
        connectedAt = Date()
        copyDone = false
        ringKey = nil
        storageNotifying = false
        clockRead = false
        nextCheck = nil
        packer = LivePacker()
        lastLiveIndex = nil
        liveLost = 0
        liveHeard = 0
        Log.write("connected: MTU \(peripheral.maximumWriteValueLength(for: .withoutResponse) + 3)")

        // Before anything else: older firmware throws audio away while it is
        // connected to something that isn't listening.
        if let audio = characteristics[OmiGATT.audioData] {
            liveOn = true
            peripheral.setNotifyValue(true, for: audio)
        }
        if let level = characteristics[OmiGATT.batteryLevel] {
            peripheral.setNotifyValue(true, for: level)
            peripheral.readValue(for: level)
        }
        guard let storage = characteristics[OmiGATT.storageData] else {
            // Firmware before 3.0.20 keeps nothing to copy. What it sends
            // live is all there is.
            Log.write("no storage service: firmware \(firmware ?? "?")")
            copyDone = true
            status(liveOn ? "Connected. This firmware only sends live; 3.0.20 or later also keeps audio while the phone is away."
                          : "This pendant's firmware can't be copied from. It needs 3.0.20 or later.")
            return
        }
        peripheral.setNotifyValue(true, for: storage)
        if let time = characteristics[OmiGATT.timeRead] {
            peripheral.readValue(for: time)
        } else {
            clockRead = true
        }
        preflightDeadline = Date().addingTimeInterval(5)
        startCopyIfReady()
    }

    private func startCopyIfReady() {
        guard session == nil, !copyDone, storageNotifying, let peripheral, peripheral.state == .connected,
              let storage = characteristics[OmiGATT.storageData] else { return }
        // The clock is worth a few seconds' wait, not more.
        guard clockRead || (preflightDeadline.map { Date() > $0 } ?? true) else { return }
        preflightDeadline = nil
        let layout = layout
        let drain = DrainSession(
            send: { [weak peripheral] bytes in peripheral?.writeValue(bytes, for: storage, type: .withResponse) },
            journalFor: { [weak self] info in
                let key = self?.key(for: info) ?? "ring-pendant"
                self?.ringKey = key
                return RecordJournal(folder: layout.stateFolder, key: key)
            },
            events: { [weak self] event in self?.handle(event) })
        session = drain
        drain.start()
    }

    /// The journal a ring's records go in. Firmware from 3.0.24 names its
    /// rings. Before that a ring has no name, and one that was wiped starts
    /// counting from zero again, which shows as the pendant having written
    /// fewer records than were already copied: that is a new ring.
    private func key(for info: RingInfo) -> String {
        if let ring = info.ringID { return "ring-" + String(ring, radix: 16) }
        let base = "ring-\(tag)-g"
        let generations = RecordJournal.all(in: layout.stateFolder).compactMap { journal -> Int? in
            journal.key.hasPrefix(base) ? Int(journal.key.dropFirst(base.count)) : nil
        }
        let nextFiles = ((try? FileManager.default.contentsOfDirectory(atPath: layout.stateFolder.path)) ?? [])
            .compactMap { name -> Int? in
                name.hasPrefix(base) && name.hasSuffix(".next") ? Int(name.dropFirst(base.count).dropLast(".next".count)) : nil
            }
        var generation = (generations + nextFiles).max() ?? 1
        let current = RecordJournal(folder: layout.stateFolder, key: "\(base)\(generation)")
        if let saved = current.nextSeq, info.writeSeq < saved {
            generation += 1
            Log.write("the ring was wiped (it has written \(info.writeSeq), \(saved) were copied): starting \(base)\(generation)")
        }
        return "\(base)\(generation)"
    }

    private func handle(_ event: DrainSession.Event) {
        switch event {
        case .info(let info):
            Log.write("ring: read \(info.readSeq) write \(info.writeSeq) holds \(info.capacity) records, dropped \(info.dropped), caps \(info.capabilities), ring \(info.ringID.map { String($0, radix: 16) } ?? "none")")
            if info.dropped > 0 { Log.write("the pendant overwrote \(info.dropped) records before they were copied") }
            // Firmware from 3.0.24 stores while connected, so nothing needs
            // hearing live; what was heard in the meantime is kept.
            if info.capabilities != 0, liveOn, let audio = characteristics[OmiGATT.audioData] {
                peripheral?.setNotifyValue(false, for: audio)
                flushLive(all: true)
                liveOn = false
            }
            if let ringKey {
                setClock(boundary: info.writeSeq, journal: RecordJournal(folder: layout.stateFolder, key: ringKey))
            }
        case .progress(let done, let total):
            progress(total > 0 ? min(1, Double(done) / Double(total)) : nil)
            status("Copying \(formatBytes(done * PendantRecord.size)) of \(formatBytes(total * PendantRecord.size))")
        case .caughtUp(let copied):
            if let connectedAt, copied > 0 {
                let seconds = max(0.1, Date().timeIntervalSince(connectedAt))
                Log.write("copied \(copied) records, \(Int(seconds)) s after connecting")
            }
            finishCopy(nextIn: Self.interval)
        case .failed(let message):
            Log.write("copy failed: \(message)")
            finishCopy(nextIn: Self.retry, problem: message)
        }
    }

    /// Sets the pendant's clock from this phone's when it is off, and notes
    /// by how much, so what it recorded under the old clock can be put right.
    private func setClock(boundary: UInt64, journal: RecordJournal) {
        guard clockRead, let time = characteristics[OmiGATT.timeWrite], let peripheral else { return }
        let unset = pendantEpoch == 0
        guard unset || abs(drift) >= 2 else { return }
        if !unset, abs(drift) > ClockCorrection.threshold {
            do { try journal.noteClock(boundary: boundary, drift: drift) } catch {
                Log.write("could not note the clock: \(error)")
            }
        }
        let seconds = UInt32(Date().timeIntervalSince1970)
        var now = seconds.littleEndian
        peripheral.writeValue(Data(bytes: &now, count: 4), for: time, type: .withResponse)
        Log.write(unset ? "the pendant's clock wasn't set: set" : "the pendant's clock was \(Int(drift)) s off: set")
        // Right from here on: the next copy on this connection has nothing to correct.
        pendantEpoch = seconds
        drift = 0
    }

    /// The copy is over, well or badly. The pendant stays connected; what
    /// recordings are over are written, and it is asked again later.
    private func finishCopy(nextIn delay: TimeInterval, problem: String? = nil) {
        copyDone = true
        session?.connectionLost()
        session = nil
        assemble()
        progress(nil)
        nextCheck = Date().addingTimeInterval(delay)
        if let problem {
            status("\(problem) Trying again shortly.")
        } else {
            status(liveOn ? "Connected. Listening." : "Connected. Up to date.")
        }
    }

    /// The pendant is gone: keep what was heard, and end what was under way.
    private func endConnection() {
        session?.connectionLost()
        session = nil
        flushLive(all: true)
        liveOn = false
        if liveHeard > 0 { Log.write("live audio: \(liveHeard) notifications heard, \(liveLost) never arrived") }
        liveLost = 0
        liveHeard = 0
    }

    private func assemble() {
        lastAssemble = Date()
        do {
            let written = try Assembler(layout: layout).run(device: peripheral?.name ?? "Omi", firmware: firmware)
            for recording in written {
                Log.write("wrote \(recording.file): \(Int(recording.seconds)) s, \(recording.bytes) bytes")
            }
            forgetOldRecordings()
            if !written.isEmpty { DispatchQueue.main.async { self.relay?.didWrite() } }
        } catch {
            Log.write("could not write recordings: \(error)")
            status("Couldn't write a recording: \(error.localizedDescription)")
        }
    }

    /// The phone's list is of what passed through it lately, not an archive:
    /// a recording the Mac has had for two weeks drops off it.
    private func forgetOldRecordings() {
        var ledger = Ledger.load(from: layout.ledgerURL)
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        let kept = ledger.recordings.filter {
            $0.importedAt > cutoff || FileManager.default.fileExists(atPath: layout.folder.appendingPathComponent($0.file).path)
        }
        guard kept.count != ledger.recordings.count else { return }
        ledger.recordings = kept
        try? ledger.save(to: layout.ledgerURL)
    }

    // MARK: Live audio

    private func live(_ notification: Data) {
        let bytes = [UInt8](notification.prefix(2))
        if bytes.count == 2 {
            let index = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
            if let last = lastLiveIndex, index != last &+ 1 { liveLost += Int(index &- last &- 1) }
            lastLiveIndex = index
        }
        liveHeard += 1
        liveBuffer += packer.receive(notification, at: Date())
    }

    /// Puts live audio heard so far on disk: every couple of seconds, and
    /// whenever listening ends.
    private func flushLive(all: Bool) {
        if all {
            liveBuffer += packer.tick(at: Date().addingTimeInterval(3600)) // whatever is half-packed
        }
        lastLiveFlush = Date()
        guard !liveBuffer.isEmpty else { return }
        let journal = RecordJournal(folder: layout.stateFolder, key: "live-\(tag)")
        let first = journal.nextSeq ?? 0
        let records = liveBuffer.enumerated().map { PendantRecord(seq: first + UInt64($0.offset), bytes: $0.element) }
        liveBuffer = []
        do { try journal.append(records) } catch { Log.write("could not save live audio: \(error)") }
    }

    // MARK: Every second the app is awake

    private func tick() {
        let now = Date()
        if liveOn {
            liveBuffer += packer.tick(at: now)
            if now.timeIntervalSince(lastLiveFlush) >= 2 { flushLive(all: false) }
        }
        if let nextCheck, now >= nextCheck {
            if peripheral?.state == .connected {
                self.nextCheck = nil
                if characteristics[OmiGATT.storageData] != nil { copyDone = false }
            } else if peripheral?.state == .disconnected, !connecting {
                self.nextCheck = nil
                connectNow()
            }
        }
        if session == nil, peripheral?.state == .connected { startCopyIfReady() }
        if let session, !session.isFinished, now.timeIntervalSince(session.lastActivity) > session.patience {
            Log.write("the pendant went quiet")
            session.timedOut()
        }
        // A recording is finished once it has been quiet for a minute.
        if session == nil, now.timeIntervalSince(lastAssemble) >= 30,
           RecordJournal.all(in: layout.stateFolder).contains(where: { !$0.isEmpty }) {
            assemble()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension PendantLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connecting = false
            connectOrScan()
        case .poweredOff: status("Bluetooth is off")
        case .unauthorized: status("Allow Omi Relay to use Bluetooth in Settings › Privacy & Security › Bluetooth")
        case .unsupported: status("This device has no Bluetooth LE")
        default: status("Waiting for Bluetooth")
        }
    }

    /// iOS started the app again for the pendant: here is the connection it kept.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        Log.write("started again by iOS for \(restored.name ?? "the pendant")")
        peripheral = restored
        restored.delegate = self
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        central.stopScan()
        Log.write("found \(peripheral.name ?? "an Omi") (\(peripheral.identifier)), signal \(RSSI)")
        remember(peripheral)
        attach(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connecting = false
        Log.write("could not connect: \(error?.localizedDescription ?? "no reason given")")
        // Asked again at once: iOS holds the request until the pendant is there.
        connectNow()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connecting = false
        endConnection()
        progress(nil)
        guard self.peripheral === peripheral else { return }
        Log.write("disconnected: \(error?.localizedDescription ?? "no reason given")")
        assemble()
        // Nothing wakes the app in the background but Bluetooth, so the
        // request to connect again goes in now, not on a timer.
        connectNow()
    }
}

// MARK: - CBPeripheralDelegate

extension PendantLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
            if characteristic.uuid == OmiGATT.firmwareRevision { peripheral.readValue(for: characteristic) }
        }
        let pending = (peripheral.services ?? []).contains { $0.characteristics == nil }
        if !pending { begin(on: peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { Log.write("notifications for \(characteristic.uuid): \(error.localizedDescription)") }
        if characteristic.uuid == OmiGATT.storageData, characteristic.isNotifying {
            storageNotifying = true
            startCopyIfReady()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        switch characteristic.uuid {
        case OmiGATT.storageData:
            session?.received(value)
        case OmiGATT.audioData:
            if liveOn { live(value) }
        case OmiGATT.batteryLevel:
            guard let level = value.first.map(Int.init), level != battery else { return }
            battery = level
            DispatchQueue.main.async { self.relay?.setBattery(level) }
        case OmiGATT.timeRead:
            let bytes = [UInt8](value.prefix(4))
            if bytes.count == 4 {
                pendantEpoch = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
                drift = pendantEpoch == 0 ? 0 : TimeInterval(pendantEpoch) - Date().timeIntervalSince1970
                Log.write(pendantEpoch == 0 ? "the pendant's clock was never set" : "the pendant's clock is \(Int(drift)) s from this phone's")
            }
            clockRead = true
            startCopyIfReady()
        case OmiGATT.firmwareRevision:
            firmware = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .controlCharacters.union(.whitespaces))
            Log.write("firmware \(firmware ?? "?")")
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { Log.write("write to \(characteristic.uuid) failed: \(error.localizedDescription)") }
    }
}
