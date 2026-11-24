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
                    Text("Whenever the pendant is near, what it has stored is copied into a folder you choose, one audio file and one note for each recording. Nothing goes through Omi's servers.")
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
                Toggle("Open at login", isOn: Binding(get: { loginOn }, set: setLogin))
                if let loginError { Text(loginError).foregroundStyle(.red).font(.callout) }
            } header: {
                Text("\(controller.engelbart != nil ? 4 : 3). Keep it running")
            } footer: {
                Text("Copying happens on its own every 15 minutes while the app is running and the pendant is near this Mac.")
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.pendantStatus)
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

            if controller.recordings.isEmpty {
                Spacer()
                Text(controller.settings.destination == nil ? "Choose a folder in Setup first." : "Nothing imported yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Table(controller.recordings) {
                    TableColumn("Started") { Text($0.start.formatted(date: .abbreviated, time: .shortened)).lineLimit(1) }
                        .width(min: 150, ideal: 190)
                    TableColumn("Length") { Text(RecordingLayout.length($0.seconds)).lineLimit(1) }
                        .width(90)
                    TableColumn("Size") { Text(formatBytes($0.bytes)).lineLimit(1) }
                        .width(70)
                    TableColumn("File") { recording in
                        Button { controller.reveal(recording) } label: {
                            Text((recording.file as NSString).lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.link)
                    }
                    .width(min: 180, ideal: 230)
                }
            }
        }
    }
}
