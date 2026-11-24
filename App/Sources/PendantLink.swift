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

    static let services = [audioService, storageService, timeService, deviceInformation]
}

/// The Bluetooth side: finding the pendant, and every so often connecting to
/// it, copying what it has stored, and letting it go again.
///
/// The pendant is left alone between copies on purpose. Firmware before
/// 3.0.24 stores nothing while something is connected to it, and loses audio
/// outright if what is connected isn't listening, so the less time this Mac
/// holds the connection the less depends on the radio. While it is
/// connected, such a pendant is listened to live, and what is heard joins
/// what was stored.
///
/// macOS keeps a connection request open until the pendant is in range, so
/// there is no scanning once a pendant is known: asking again is all it
/// takes to connect the moment it comes near.
///
/// Everything here runs on `queue`; the controller is told on the main queue.
final class PendantLink: NSObject {
    /// How long the pendant is left alone after a copy.
    static let interval: TimeInterval = 15 * 60
    private static let retry: TimeInterval = 60

    private let queue = DispatchQueue(label: "com.mathetic.OmiImport.pendant")
    private weak var controller: ImportController?
    private var central: CBCentralManager!
    private var timer: DispatchSourceTimer?

    // What setup chose.
    private var folder: URL?
    private var savedPendant: UUID?

    // The connection.
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var firmware: String?
    private var connecting = false
    private var nextCheck: Date?
    private var connectedAt: Date?

    // One copy.
    private var session: DrainSession?
    private var storageNotifying = false
    private var clockRead = false
    private var preflightDeadline: Date?
    /// The pendant's clock, and how far it was from this Mac's, read on connecting.
    private var pendantEpoch: UInt32 = 0
    private var drift: TimeInterval = 0
    private var ringKey: String?
    /// This connection's copy is over; the pendant is being let go.
    private var cycleDone = false

    // Live audio.
    private var packer = LivePacker()
    private var liveBuffer: [Data] = []
    private var liveOn = false
    private var lastLiveIndex: UInt16?
    private var liveLost = 0
    private var lastLiveFlush = Date()
    private var lastAssemble = Date()

    init(controller: ImportController) {
        self.controller = controller
        super.init()
    }

    // MARK: From the controller (any queue)

    func start(folder: URL?, pendant: UUID?) {
        queue.async {
            self.folder = folder
            self.savedPendant = pendant
            self.central = CBCentralManager(delegate: self, queue: self.queue,
                                            options: [CBCentralManagerOptionShowPowerAlertKey: true])
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func setFolder(_ folder: URL?) {
        queue.async {
            self.folder = folder
            self.nextCheck = nil
            if self.peripheral == nil { self.connectOrScan() } else { self.connectNow() }
        }
    }

    func importNow() {
        queue.async {
            self.nextCheck = nil
            if self.peripheral == nil { self.connectOrScan() } else { self.connectNow() }
        }
    }

    func forget() {
        queue.async {
            if let peripheral = self.peripheral { self.central.cancelPeripheralConnection(peripheral) }
            self.endSession()
            self.peripheral = nil
            self.savedPendant = nil
            self.connecting = false
            self.characteristics = [:]
            self.queue.asyncAfter(deadline: .now() + 1) { self.connectOrScan() }
        }
    }

    // MARK: Telling the controller

    private func status(_ text: String) {
        DispatchQueue.main.async { self.controller?.setPendantStatus(text) }
    }

    private func progress(_ value: ImportController.Progress?) {
        DispatchQueue.main.async { self.controller?.setProgress(value) }
    }

    private var name: String { peripheral?.name ?? "your pendant" }

    /// A name for this pendant in file names: the start of the identifier
    /// macOS gives it, which is the same every time on this Mac.
    private var tag: String {
        String((peripheral?.identifier.uuidString ?? "pendant").prefix(8)).lowercased()
    }

    private var layout: RecordingLayout? { folder.map { RecordingLayout(folder: $0) } }

    // MARK: Connecting

    private func connectOrScan() {
        guard central?.state == .poweredOn else { return }
        guard folder != nil else { status("Choose a folder first"); return }
        if let saved = savedPendant, let known = central.retrievePeripherals(withIdentifiers: [saved]).first {
            attach(known)
            return
        }
        // Not met before. A pendant another app on this Mac is connected to
        // doesn't advertise, but macOS can hand it over.
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
        DispatchQueue.main.async { self.controller?.remember(pendant: identifier, name: name) }
    }

    private func attach(_ found: CBPeripheral) {
        peripheral = found
        found.delegate = self
        connectNow()
    }

    private func connectNow() {
        guard let peripheral, central.state == .poweredOn, folder != nil else { return }
        guard peripheral.state == .disconnected, !connecting else { return }
        connecting = true
        status("Waiting for \(name) to come into range")
        central.connect(peripheral, options: nil)
    }

    private func disconnect(nextIn delay: TimeInterval) {
        nextCheck = Date().addingTimeInterval(delay)
        if let peripheral, peripheral.state != .disconnected { central.cancelPeripheralConnection(peripheral) }
    }

    // MARK: One copy

    /// Services are known. Listen first, then ask.
    private func begin(on peripheral: CBPeripheral) {
        guard let storage = characteristics[OmiGATT.storageData] else {
            Log.write("no storage service: firmware \(firmware ?? "?")")
            status("This pendant's firmware can't be copied from. It needs 3.0.20 or later.")
            disconnect(nextIn: 3600)
            return
        }
        connectedAt = Date()
        cycleDone = false
        ringKey = nil
        storageNotifying = false
        clockRead = false
        packer = LivePacker()
        lastLiveIndex = nil
        liveLost = 0
        Log.write("connected: MTU \(peripheral.maximumWriteValueLength(for: .withoutResponse) + 3)")

        // Before anything else: older firmware throws audio away while it is
        // connected to something that isn't listening.
        if let audio = characteristics[OmiGATT.audioData] {
            liveOn = true
            peripheral.setNotifyValue(true, for: audio)
        }
        peripheral.setNotifyValue(true, for: storage)
        if let time = characteristics[OmiGATT.timeRead] {
            peripheral.readValue(for: time)
        } else {
            clockRead = true
        }
        preflightDeadline = Date().addingTimeInterval(5)
        startDrainIfReady()
    }

    private func startDrainIfReady() {
        guard session == nil, !cycleDone, storageNotifying, let peripheral, peripheral.state == .connected,
              let layout, let storage = characteristics[OmiGATT.storageData] else { return }
        // The clock is worth a few seconds' wait, not more.
        guard clockRead || (preflightDeadline.map { Date() > $0 } ?? true) else { return }
        preflightDeadline = nil
        let drain = DrainSession(
            send: { [weak peripheral] bytes in peripheral?.writeValue(bytes, for: storage, type: .withResponse) },
            journalFor: { [weak self] info in
                let key = self?.key(for: info, in: layout) ?? "ring-pendant"
                self?.ringKey = key
                return RecordJournal(folder: layout.stateFolder, key: key)
            },
            events: { [weak self] event in self?.handle(event, layout: layout) })
        session = drain
        status("Connected to \(name)")
        drain.start()
    }

    /// The journal a ring's records go in. Firmware from 3.0.24 names its
    /// rings. Before that a ring has no name, and one that was wiped starts
    /// counting from zero again, which shows as the pendant having written
    /// fewer records than were already copied: that is a new ring.
    private func key(for info: RingInfo, in layout: RecordingLayout) -> String {
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

    private func handle(_ event: DrainSession.Event, layout: RecordingLayout) {
        switch event {
        case .info(let info):
            Log.write("ring: read \(info.readSeq) write \(info.writeSeq) holds \(info.capacity) records, dropped \(info.dropped), caps \(info.capabilities), ring \(info.ringID.map { String($0, radix: 16) } ?? "none")")
            if info.dropped > 0 { Log.write("the pendant overwrote \(info.dropped) records before they were copied") }
            // Firmware from 3.0.24 stores while connected, so nothing needs
            // hearing live; what was heard in the meantime is kept.
            if info.capabilities != 0, liveOn, let audio = characteristics[OmiGATT.audioData] {
                peripheral?.setNotifyValue(false, for: audio)
                liveOn = false
            }
            if let ringKey {
                setClock(boundary: info.writeSeq, journal: RecordJournal(folder: layout.stateFolder, key: ringKey))
            }
        case .progress(let done, let total):
            progress(.init(done: done * PendantRecord.size, total: total * PendantRecord.size))
            status("Copying \(formatBytes(done * PendantRecord.size)) of \(formatBytes(total * PendantRecord.size))")
        case .caughtUp(let copied):
            if let connectedAt, copied > 0 {
                let seconds = max(0.1, Date().timeIntervalSince(connectedAt))
                Log.write("copied \(copied) records in \(Int(seconds)) s (\(Int(Double(copied) / seconds)) a second)")
            }
            finishCycle(nextIn: Self.interval)
        case .failed(let message):
            Log.write("copy failed: \(message)")
            finishCycle(nextIn: Self.retry, problem: message)
        }
    }

    /// Sets the pendant's clock from this Mac's when it is off, and notes by
    /// how much, so what it recorded under the old clock can be put right.
    private func setClock(boundary: UInt64, journal: RecordJournal) {
        guard clockRead, let time = characteristics[OmiGATT.timeWrite], let peripheral else { return }
        let unset = pendantEpoch == 0
        guard unset || abs(drift) >= 2 else { return }
        if !unset, abs(drift) > ClockCorrection.threshold {
            do { try journal.noteClock(boundary: boundary, drift: drift) } catch {
                Log.write("could not note the clock: \(error)")
            }
        }
        var now = UInt32(Date().timeIntervalSince1970).littleEndian
        peripheral.writeValue(Data(bytes: &now, count: 4), for: time, type: .withResponse)
        Log.write(unset ? "the pendant's clock wasn't set: set" : "the pendant's clock was \(Int(drift)) s off: set")
    }

    /// The copy is over, well or badly: finish what recordings are over, let
    /// the pendant go, and come back later.
    private func finishCycle(nextIn delay: TimeInterval, problem: String? = nil) {
        cycleDone = true
        endSession()
        assemble()
        progress(nil)
        let at = Date().addingTimeInterval(delay).formatted(date: .omitted, time: .shortened)
        status(problem.map { "\($0) Next try at \(at)." } ?? "Up to date. Next check at \(at).")
        DispatchQueue.main.async { self.controller?.didCheck() }
        disconnect(nextIn: delay)
    }

    private func endSession() {
        session?.connectionLost()
        session = nil
        flushLive(all: true)
        liveOn = false
        if liveLost > 0 { Log.write("live audio: \(liveLost) notifications never arrived") }
        liveLost = 0
    }

    private func assemble() {
        guard let layout else { return }
        lastAssemble = Date()
        do {
            let written = try Assembler(layout: layout).run(device: peripheral?.name ?? "Omi", firmware: firmware)
            for recording in written {
                Log.write("wrote \(recording.file): \(Int(recording.seconds)) s, \(recording.bytes) bytes")
            }
            if !written.isEmpty { DispatchQueue.main.async { self.controller?.didImport(written) } }
        } catch {
            Log.write("could not write recordings: \(error)")
            status("Couldn't write to the folder: \(error.localizedDescription)")
        }
    }

    // MARK: Live audio

    private func live(_ notification: Data) {
        let bytes = [UInt8](notification.prefix(2))
        if bytes.count == 2 {
            let index = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
            if let last = lastLiveIndex, index != last &+ 1 { liveLost += Int(index &- last &- 1) }
            lastLiveIndex = index
        }
        liveBuffer += packer.receive(notification, at: Date())
    }

    /// Puts live audio heard so far on disk: every couple of seconds, and
    /// whenever the connection ends.
    private func flushLive(all: Bool) {
        if all {
            liveBuffer += packer.tick(at: Date().addingTimeInterval(3600)) // whatever is half-packed
        }
        lastLiveFlush = Date()
        guard !liveBuffer.isEmpty, let layout else { return }
        let journal = RecordJournal(folder: layout.stateFolder, key: "live-\(tag)")
        let first = journal.nextSeq ?? 0
        let records = liveBuffer.enumerated().map { PendantRecord(seq: first + UInt64($0.offset), bytes: $0.element) }
        liveBuffer = []
        do { try journal.append(records) } catch { Log.write("could not save live audio: \(error)") }
    }

    // MARK: Every second

    private func tick() {
        let now = Date()
        if liveOn {
            liveBuffer += packer.tick(at: now)
            if now.timeIntervalSince(lastLiveFlush) >= 2 { flushLive(all: false) }
        }
        if session == nil, peripheral?.state == .connected { startDrainIfReady() }
        if let session, !session.isFinished, now.timeIntervalSince(session.lastActivity) > session.patience {
            Log.write("the pendant went quiet")
            session.timedOut()
        }
        // A recording is finished once it has been quiet for a minute, which
        // may be well after the pendant was let go.
        if session == nil, now.timeIntervalSince(lastAssemble) >= 30, let layout,
           RecordJournal.all(in: layout.stateFolder).contains(where: { !$0.isEmpty }) {
            assemble()
        }
        if let nextCheck, now >= nextCheck, peripheral?.state == .disconnected, !connecting {
            self.nextCheck = nil
            connectNow()
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
        case .unauthorized: status("Allow Omi Import to use Bluetooth in System Settings › Privacy & Security › Bluetooth")
        case .unsupported: status("This Mac has no Bluetooth LE")
        default: status("Waiting for Bluetooth")
        }
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
        connecting = false
        cycleDone = false
        storageNotifying = false
        characteristics = [:]
        status("Connected to \(name)")
        peripheral.discoverServices(OmiGATT.services)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connecting = false
        Log.write("could not connect: \(error?.localizedDescription ?? "no reason given")")
        nextCheck = Date().addingTimeInterval(10)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connecting = false
        let midCopy = session != nil
        endSession()
        progress(nil)
        guard self.peripheral === peripheral else { return }
        if midCopy || nextCheck == nil {
            // Not let go on purpose: it went out of range or was switched off.
            Log.write("disconnected: \(error?.localizedDescription ?? "no reason given")")
            assemble()
            connectNow()
        }
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
            startDrainIfReady()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        switch characteristic.uuid {
        case OmiGATT.storageData:
            session?.received(value)
        case OmiGATT.audioData:
            if liveOn { live(value) }
        case OmiGATT.timeRead:
            let bytes = [UInt8](value.prefix(4))
            if bytes.count == 4 {
                pendantEpoch = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
                drift = pendantEpoch == 0 ? 0 : TimeInterval(pendantEpoch) - Date().timeIntervalSince1970
                Log.write(pendantEpoch == 0 ? "the pendant's clock was never set" : "the pendant's clock is \(Int(drift)) s from this Mac's")
            }
            clockRead = true
            startDrainIfReady()
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
