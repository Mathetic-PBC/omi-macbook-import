import AppKit
import OmiImportCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    enum Pane: Hashable { case setup, recordings }

    @EnvironmentObject private var controller: ImportController
    @State private var pane: Pane? = .setup

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Label("Setup", systemImage: "checklist").tag(Pane.setup)
                Label("Recordings", systemImage: "waveform").tag(Pane.recordings)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            switch pane {
            case .recordings: RecordingsPane()
            default: SetupPane()
            }
        }
        .onAppear {
            if controller.settings.destination != nil { pane = .recordings }
            #if DEBUG
            switch ProcessInfo.processInfo.environment["OMI_IMPORT_PANE"] {
            case "setup": pane = .setup
            case "recordings": pane = .recordings
            default: break
            }
            #endif
        }
        .alert(controller.engelbartQuestion?.title ?? "", isPresented: Binding(
            get: { controller.engelbartQuestion != nil },
            set: { if !$0 { controller.engelbartQuestion = nil } })
        ) {
            Button("Add to Engelbart") { controller.answerEngelbart(add: true) }
            Button("Not Now", role: .cancel) { controller.answerEngelbart(add: false) }
        } message: {
            Text(controller.engelbartQuestion?.message ?? "")
        }
    }
}

// MARK: - Setup

private struct SetupPane: View {
    @EnvironmentObject private var controller: ImportController
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Copy what your Omi recorded onto this Mac")
                        .font(.title2.weight(.semibold))
                    Text("What the pendant has stored is copied straight off it into a folder you choose, an audio file and a note for each recording. What the Omi app already took can come from Omi's cloud, as notes.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent {
                    HStack {
                        Button("Choose…") { controller.chooseFolder() }
                        Button("New Folder…") { controller.createFolder() }
                    }
                } label: {
                    if let folder = controller.settings.destinationURL {
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .textSelection(.enabled)
                    } else {
                        Text("No folder yet").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("1. Choose where recordings go")
            } footer: {
                if let folder = controller.settings.destinationURL, controller.engelbart != nil, !Engelbart.canList(folder) {
                    Text("Engelbart only lists folders inside your home folder, so it won't show this one.")
                }
            }

            if controller.engelbart != nil {
                Section {
                    EngelbartRow()
                } header: {
                    Text("2. Engelbart")
                } footer: {
                    Text("The folder is added to Engelbart's library once, as a folder. Engelbart lists what is in it as it is now, so every later recording is there too, and nothing is copied.")
                }
            }

            Section {
                PendantRow()
            } header: {
                Text("\(controller.engelbart != nil ? 3 : 2). Pendant")
            } footer: {
                Text("The pendant connects to one device at a time. Quit the Omi app on your phone, or this Mac can't reach it.")
            }

            Section {
                CloudRow()
            } header: {
                Text("\(controller.engelbart != nil ? 4 : 3). Omi's cloud")
            } footer: {
                Text("What the Omi app on your phone already took off the pendant is in Omi's cloud. With a key from [app.omi.me/developers](https://app.omi.me/developers) that can read conversations, each one is copied here as a note with its transcript. Omi's cloud doesn't give out the audio.")
            }

            Section {
                Toggle("Open at login", isOn: Binding(get: { loginOn }, set: setLogin))
                if let loginError { Text(loginError).foregroundStyle(.red).font(.callout) }
            } header: {
                Text("\(controller.engelbart != nil ? 5 : 4). Keep it running")
            } footer: {
                Text("While the app is running, the pendant is copied from every 15 minutes when it is near, and Omi's cloud is checked when the Mac starts or wakes and every half hour.")
            }
        }
        .formStyle(.grouped)
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginOn = SMAppService.mainApp.status == .enabled
    }
}

private struct EngelbartRow: View {
    @EnvironmentObject private var controller: ImportController

    var body: some View {
        switch controller.engelbartStatus {
        case .added:
            LabeledContent("In Engelbart's library") {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .waitingForQuit:
            LabeledContent {
                Button("Quit Engelbart and Add") { controller.quitEngelbartAndAdd() }
                    .disabled(controller.engelbartBusy)
            } label: {
                Text("Added when Engelbart next closes")
            }
        case .notAdded:
            LabeledContent {
                Button("Add to Engelbart") { controller.answerEngelbart(add: true) }
                    .disabled(controller.settings.destination == nil || controller.engelbartBusy)
            } label: {
                Text(controller.settings.destination == nil ? "Choose a folder first" : "Not in Engelbart's library")
            }
        case .failed(let message):
            LabeledContent {
                Button("Try Again") { controller.answerEngelbart(add: true) }
                    .disabled(controller.engelbartBusy)
            } label: {
                Text(message).foregroundStyle(.red)
            }
        }
    }
}

private struct CloudRow: View {
    @EnvironmentObject private var controller: ImportController
    @State private var key = ""

    var body: some View {
        if controller.cloudConnected {
            LabeledContent {
                Button("Disconnect") { controller.disconnectCloud() }
            } label: {
                Text(controller.cloudStatus ?? "Connected")
                    .foregroundStyle(controller.cloudProblem ? Color.red : Color.primary)
            }
        } else {
            LabeledContent {
                Button("Connect") {
                    controller.connectCloud(key: key)
                    key = ""
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || controller.settings.destination == nil)
            } label: {
                SecureField("Developer key", text: $key, prompt: Text("omi_dev_…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            if let status = controller.cloudStatus, controller.cloudProblem {
                Text(status).foregroundStyle(.red).font(.callout)
            }
        }
    }
}

private struct PendantRow: View {
    @EnvironmentObject private var controller: ImportController

    var body: some View {
        LabeledContent {
            HStack {
                if controller.settings.pendant != nil {
                    Button("Forget") { controller.forgetPendant() }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.settings.pendantName ?? "No pendant yet")
                Text(controller.pendantStatus).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Recordings

private struct RecordingsPane: View {
    @EnvironmentObject private var controller: ImportController

    /// A file's name as the table shows it: a note that has a title is
    /// shown by it, since the row already says when.
    static func shown(_ file: String) -> String {
        let name = (file as NSString).lastPathComponent
        guard let match = name.range(of: #"^\d{4}-\d\d-\d\d \d\d-\d\d-\d\d( \d+)? (?=\D)"#, options: .regularExpression) else { return name }
        return String(name[match.upperBound...])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.pendantStatus)
                    if let cloud = controller.cloudStatus {
                        Text("Cloud: \(cloud)").font(.callout).foregroundStyle(.secondary)
                    }
                    if let progress = controller.progress {
                        ProgressView(value: progress.fraction)
                            .frame(maxWidth: 320)
                    }
                }
                Spacer()
                Button("Open Folder") { controller.openFolder() }
                    .disabled(controller.settings.destination == nil)
                Button("Import Now") { controller.importNow() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canImportNow)
            }
            .padding(16)

            if controller.rows.isEmpty {
                Spacer()
                Text(controller.settings.destination == nil ? "Choose a folder in Setup first." : "Nothing imported yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Table(controller.rows) {
                    TableColumn("Started") { Text($0.start.formatted(date: .abbreviated, time: .shortened)).lineLimit(1) }
                        .width(min: 150, ideal: 180)
                    TableColumn("Length") { Text($0.seconds > 0 ? RecordingLayout.length($0.seconds) : "").lineLimit(1) }
                        .width(90)
                    TableColumn("From") { Text($0.from).lineLimit(1) }
                        .width(70)
                    TableColumn("File") { recording in
                        Button { controller.reveal(recording) } label: {
                            Text(Self.shown(recording.file))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .buttonStyle(.link)
                    }
                    .width(min: 180, ideal: 230)
                }
            }
        }
    }
}
