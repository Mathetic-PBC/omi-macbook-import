import AppKit
import Combine
import OmiImportCore
import SwiftUI

/// The app's state: the chosen folder, Engelbart, the pendant, and what has
/// been imported. Everything the windows and the menu show comes from here.
@MainActor
final class ImportController: ObservableObject {
    static let shared = ImportController()

    @Published var settings = Settings.load() { didSet { if settings != oldValue { settings.save() } } }
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var pendantStatus = "Not started"
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

    struct Question: Equatable {
        var title: String
        var message: String
    }

    enum EngelbartStatus: Equatable {
        case notAdded, waitingForQuit, added
        case failed(String)
    }

    private var pendant: PendantLink?
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
        let link = PendantLink(controller: self)
        pendant = link
        link.start(folder: settings.destinationURL, pendant: settings.pendant.flatMap(UUID.init(uuidString:)))
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
        pendant?.setFolder(url)
    }

    func openFolder() {
        guard let url = settings.destinationURL else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ recording: Recording) {
        guard let folder = settings.destinationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(recording.file)])
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

    // MARK: Pendant

    var canImportNow: Bool { settings.destination != nil && !isTransferring }

    func importNow() { pendant?.importNow() }

    func forgetPendant() {
        pendant?.forget()
        settings.pendant = nil
        settings.pendantName = nil
    }

    func setPendantStatus(_ text: String) { pendantStatus = text }

    func setProgress(_ value: Progress?) {
        progress = value
        isTransferring = value != nil
    }

    func remember(pendant identifier: UUID, name: String) {
        settings.pendant = identifier.uuidString
        settings.pendantName = name
    }

    /// A copy finished, with or without anything new.
    func didCheck() { settings.lastImport = Date() }

    func didImport(_ written: [Recording]) { reloadLedger() }

    func reloadLedger() {
        guard let folder = settings.destinationURL else { recordings = []; return }
        recordings = Ledger.load(from: RecordingLayout(folder: folder).ledgerURL).recordings.sorted { $0.start > $1.start }
    }

    #if DEBUG
    /// For snapshots: shows what the settings say, starts nothing.
    func loadForSnapshot() {
        reloadLedger()
        refreshEngelbartStatus()
        pendantStatus = ProcessInfo.processInfo.environment["OMI_IMPORT_STATUS"] ?? "Looking for your pendant"
    }
    #endif
}
