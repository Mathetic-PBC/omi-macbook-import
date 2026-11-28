import AppKit
import Combine
import OmiImportCore
import SwiftUI

/// The app's state: the chosen folder, Engelbart, the phone, Omi's cloud,
/// and what is held. Everything the windows and the menu show comes from here.
@MainActor
final class ImportController: ObservableObject {
    static let shared = ImportController()

    @Published var settings = Settings.load() { didSet { if settings != oldValue { settings.save() } } }
    @Published private(set) var rows: [Row] = []
    /// What Omi's cloud last said; nil with no key.
    @Published private(set) var cloudStatus: String?
    @Published private(set) var cloudProblem = false
    @Published private(set) var cloudConnected = CloudKey.value?.isEmpty == false
    /// What the phone last did; nil before the app is listening.
    @Published private(set) var phoneStatus: String?
    @Published private(set) var phoneProblem = false
    /// The pairing code, shown in Setup for typing into the phone.
    @Published private(set) var phoneCode = PairingCode.value.flatMap(Pairing.normalize)
    @Published private(set) var progress: Progress?
    @Published private(set) var isTransferring = false
    @Published var engelbartQuestion: Question?
    @Published private(set) var engelbartStatus: EngelbartStatus = .notAdded
    @Published private(set) var engelbartBusy = false
    private(set) var engelbart = Engelbart.detect()

    struct Progress: Equatable {
        var done: Int
        var total: Int
        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    }

    /// One line of the Recordings pane: audio the phone took off the
    /// pendant, or a conversation from Omi's cloud.
    struct Row: Identifiable, Equatable {
        var id: String { file }
        var file: String
        var start: Date
        var seconds: Double
        var from: String
    }

    struct Question: Equatable {
        var title: String
        var message: String
    }

    enum EngelbartStatus: Equatable {
        case notAdded, waitingForQuit, added
        case failed(String)
    }

    private var phone: PhoneLink?
    private var cloud: CloudLink?
    private var observers: [NSObjectProtocol] = []

    func start() {
        reloadLedger()
        refreshEngelbartStatus()
        // An app quitting may be Engelbart letting go of its library.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.addToEngelbartIfWaiting() }
        })
        // Engelbart may have closed while this app wasn't running.
        addToEngelbartIfWaiting()
        let cloud = CloudLink(controller: self)
        self.cloud = cloud
        cloud.start()
        let phone = PhoneLink(controller: self)
        self.phone = phone
        if phoneCode == nil, settings.destination != nil { makePhoneCode() }
        phone.restart()
    }

    // MARK: Folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder recordings are copied into."
        panel.directoryURL = settings.destinationURL ?? Self.suggestedParent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(url)
    }

    func createFolder() {
        let panel = NSSavePanel()
        panel.title = "New Folder for Recordings"
        panel.prompt = "Create"
        panel.nameFieldLabel = "Folder name:"
        panel.nameFieldStringValue = "Omi"
        panel.canCreateDirectories = true
        panel.directoryURL = Self.suggestedParent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            use(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// ~/personal, the Personal project's folder in Engelbart, when it is
    /// there; else the home folder.
    private static var suggestedParent: URL {
        let personal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("personal", isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: personal.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? personal : FileManager.default.homeDirectoryForCurrentUser
    }

    private func use(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard path != settings.destination else { return }
        settings.destination = path
        Log.write("folder: \(path)")
        reloadLedger()
        refreshEngelbartStatus()
        askAboutEngelbart()
        if phoneCode == nil { makePhoneCode() }
        phone?.restart()
        cloud?.reset()
    }

    func openFolder() {
        guard let url = settings.destinationURL else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ row: Row) {
        guard let folder = settings.destinationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(row.file)])
    }

    // MARK: Engelbart

    private func askAboutEngelbart() {
        engelbart = Engelbart.detect()
        guard engelbart != nil, let folder = settings.destinationURL, !settings.inEngelbart else { return }
        let name = folder.lastPathComponent
        var message = "Engelbart will list the recordings in “\(name)” where they are. Nothing is copied, and later recordings appear there too."
        if !Engelbart.canList(folder) {
            message += "\n\nThis folder is outside your home folder, which Engelbart doesn't list from. It would show as missing."
        }
        engelbartQuestion = Question(title: "Add “\(name)” to Engelbart's library?", message: message)
    }

    func answerEngelbart(add: Bool) {
        engelbartQuestion = nil
        settings.engelbart = add ? .yes : .no
        guard add else { refreshEngelbartStatus(); return }
        addToEngelbart()
    }

    private func refreshEngelbartStatus() {
        if settings.inEngelbart {
            engelbartStatus = .added
        } else if settings.engelbart == .yes, settings.destination != nil {
            engelbartStatus = .waitingForQuit
        } else {
            engelbartStatus = .notAdded
        }
    }

    private func addToEngelbartIfWaiting() {
        guard engelbartStatus == .waitingForQuit, !engelbartBusy else { return }
        addToEngelbart()
    }

    /// Writes the row now if no copy of Engelbart has the library open;
    /// otherwise waits for Engelbart to close.
    private func addToEngelbart() {
        guard let install = Engelbart.detect() ?? engelbart, let folder = settings.destinationURL else { return }
        engelbart = install
        engelbartBusy = true
        let destination = folder.path
        Task.detached(priority: .utility) {
            let outcome: Result<Engelbart.State, Error>
            do {
                outcome = .success(try Engelbart.run("add", folder: folder, name: folder.lastPathComponent, install: install))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { self.finishEngelbart(outcome, folder: destination) }
        }
    }

    private func finishEngelbart(_ outcome: Result<Engelbart.State, Error>, folder: String) {
        engelbartBusy = false
        switch outcome {
        case .success(.present(let id)):
            settings.engelbartFolder = folder
            settings.engelbartRowID = id
            Log.write("engelbart: folder is in the library as \(id)")
        case .success(.absent):
            break
        case .failure(Engelbart.Problem.inUse):
            Log.write("engelbart: library is open; adding when Engelbart closes")
        case .failure(let error):
            Log.write("engelbart: \(error.localizedDescription)")
            engelbartStatus = .failed(error.localizedDescription)
            return
        }
        refreshEngelbartStatus()
    }

    func quitEngelbartAndAdd() {
        guard let install = engelbart else { return }
        engelbartBusy = true
        Task {
            let (released, reopen) = await Engelbart.quitHolders(of: install)
            engelbartBusy = false
            guard released else {
                engelbartStatus = .failed("Engelbart didn't close. Quit it yourself and the folder is added then.")
                return
            }
            addToEngelbart()
            // Open Engelbart again once the row is written.
            if let reopen {
                while engelbartBusy { try? await Task.sleep(nanoseconds: 300_000_000) }
                NSWorkspace.shared.openApplication(at: reopen, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        }
    }

    // MARK: The phone

    var canImportNow: Bool { settings.destination != nil && cloudConnected }

    /// Looks at Omi's cloud now. The phone sends by itself.
    func importNow() {
        cloud?.reset()
    }

    func setPhoneStatus(_ text: String?, problem: Bool = false) {
        phoneStatus = text
        phoneProblem = problem
    }

    func setProgress(_ value: Progress?) {
        progress = value
        isTransferring = value != nil
    }

    func didReceive(_ recording: Recording) {
        settings.lastImport = Date()
        reloadLedger()
    }

    private func makePhoneCode() {
        let code = Pairing.newCode()
        guard PairingCode.save(code) else { return }
        phoneCode = code
    }

    /// A new code: the phone paired before can no longer send until it is
    /// given this one.
    func newPhoneCode() {
        makePhoneCode()
        phone?.restart()
    }

    func reloadLedger() {
        guard let folder = settings.destinationURL else { rows = []; return }
        let layout = RecordingLayout(folder: folder)
        let pendant = Ledger.load(from: layout.ledgerURL).recordings.map {
            Row(file: $0.file, start: $0.start, seconds: $0.seconds, from: "Pendant")
        }
        let cloud = CloudState.load(from: layout.cloudStateURL).items.values.map {
            Row(file: $0.file, start: $0.start, seconds: $0.seconds, from: "Cloud")
        }
        rows = (pendant + cloud).sorted { $0.start > $1.start }
    }

    // MARK: Omi's cloud

    func setCloudStatus(_ text: String?, problem: Bool = false) {
        cloudStatus = text
        cloudProblem = problem
    }

    /// Keeps the developer key and checks the cloud with it at once.
    func connectCloud(key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard CloudKey.save(key) else {
            setCloudStatus("The key couldn't be saved to your keychain.", problem: true)
            return
        }
        cloudConnected = true
        cloud?.reset()
    }

    func disconnectCloud() {
        CloudKey.remove()
        cloudConnected = false
        setCloudStatus(nil)
    }

    #if DEBUG
    /// For snapshots: shows what the settings say, starts nothing.
    func loadForSnapshot() {
        reloadLedger()
        refreshEngelbartStatus()
        phoneStatus = ProcessInfo.processInfo.environment["OMI_IMPORT_STATUS"] ?? "Waiting for your phone"
        phoneCode = phoneCode ?? "0123456789ABCDEFGHJK"
        if let status = ProcessInfo.processInfo.environment["OMI_IMPORT_CLOUD_STATUS"] {
            cloudConnected = true
            cloudStatus = status
        }
    }
    #endif
}
