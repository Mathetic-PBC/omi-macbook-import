import Foundation
import OmiImportCore

/// The code the phone app is given once, kept in the login keychain.
let PairingCode = Secret(service: "com.mathetic.OmiImport.phone", account: "pairing-code", debugVariable: "OMI_IMPORT_PAIRING")

/// The phone's side of things as this Mac sees it: listens for Omi Relay,
/// takes the recordings it sends, and puts them in the import folder.
///
/// This Mac never talks to the pendant. The phone does that, and holds each
/// recording only until this Mac has said it is stored.
@MainActor
final class PhoneLink {
    private weak var controller: ImportController?
    private var server: HandoffServer?

    init(controller: ImportController) {
        self.controller = controller
    }

    private var port: UInt16? {
        #if DEBUG
        // A debug build listens only where it is told to, and stays off
        // Bonjour, so a real phone never finds it.
        return ProcessInfo.processInfo.environment["OMI_IMPORT_PORT"].flatMap { UInt16($0) }
        #else
        return Handoff.port
        #endif
    }

    private var advertises: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    /// Starts listening, or starts again after the folder or the code changed.
    func restart() {
        server?.stop()
        server = nil
        guard let controller, let folder = controller.settings.destinationURL else { return }
        guard let code = PairingCode.value.flatMap(Pairing.normalize), let port else {
            controller.setPhoneStatus("Not listening")
            return
        }
        let server = HandoffServer(layout: RecordingLayout(folder: folder), code: code, port: port, advertise: advertises) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            Log.write("phone: could not listen: \(error)")
            controller.setPhoneStatus("Couldn't listen for your phone: \(error.localizedDescription)", problem: true)
        }
    }

    private func handle(_ event: HandoffServer.Event) {
        guard let controller else { return }
        switch event {
        case .ready(let port):
            Log.write("phone: listening on port \(port)")
            if controller.phoneStatus == nil || controller.phoneProblem {
                controller.setPhoneStatus("Waiting for your phone")
            }
            #if DEBUG
            print("phone: listening on \(port)")
            #endif
        case .failed(let why):
            Log.write("phone: listener failed: \(why)")
            controller.setPhoneStatus("Couldn't listen for your phone. Is another copy of Omi Import running?", problem: true)
        case .receiving(let done, let total):
            controller.setProgress(.init(done: done, total: total))
            controller.setPhoneStatus("Receiving \(formatBytes(done)) of \(formatBytes(total))")
        case .stored(let recording):
            Log.write("phone: stored \(recording.file): \(Int(recording.seconds)) s, \(recording.bytes) bytes")
            controller.setProgress(nil)
            controller.didReceive(recording)
            controller.setPhoneStatus("Last recording arrived at \(Date().formatted(date: .omitted, time: .shortened))")
            #if DEBUG
            print("phone: stored \(recording.file)")
            #endif
        case .problem(let why):
            Log.write("phone: \(why)")
            controller.setProgress(nil)
            controller.setPhoneStatus(why, problem: true)
        }
    }
}
