import OmiImportCore
import SwiftUI

@main
struct OmiRelayApp: App {
    @StateObject private var relay = Relay.shared

    init() {
        // Bluetooth is set up as the app starts, not when the screen
        // appears: iOS starts the app in the background for the pendant, and
        // then no screen ever does.
        #if DEBUG
        if ProcessInfo.processInfo.environment["OMI_RELAY_SAMPLE"] == "1" {
            Relay.shared.loadSample()
            return
        }
        #endif
        Relay.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RelayView().environmentObject(relay)
        }
    }
}

struct RelayView: View {
    @EnvironmentObject private var relay: Relay
    @Environment(\.scenePhase) private var scenePhase
    @State private var code = ""
    @State private var codeRefused = false
    @State private var confirmingUnpair = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(relay.pendantName ?? "No pendant yet")
                            Spacer()
                            if let battery = relay.battery {
                                Label("\(battery)%", systemImage: batterySymbol(battery))
                                    .labelStyle(.titleAndIcon)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(relay.pendantStatus).font(.callout).foregroundStyle(.secondary)
                        if let progress = relay.progress { ProgressView(value: progress) }
                    }
                    .swipeActions {
                        if relay.pendantName != nil {
                            Button("Forget", role: .destructive) { relay.forgetPendant() }
                        }
                    }
                } header: {
                    Text("Pendant")
                } footer: {
                    if relay.pendantName == nil {
                        Text("Have the pendant on and nearby. Remove the Omi app from this phone first: the pendant gives each recording to one app only.")
                    }
                }

                Section {
                    if relay.paired {
                        Text(relay.macStatus)
                            .foregroundStyle(relay.macProblem ? Color.red : Color.primary)
                            .swipeActions {
                                Button("Unpair", role: .destructive) { confirmingUnpair = true }
                            }
                        TextField("Mac's address when away (optional)", text: $relay.macAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.callout)
                    } else {
                        TextField("Pairing code", text: $code, prompt: Text("XXXXX-XXXXX-XXXXX-XXXXX"))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                            .onSubmit(pair)
                        Button("Pair", action: pair)
                            .disabled(Pairing.normalize(code) == nil)
                        if codeRefused {
                            Text("That isn't a whole code.").font(.callout).foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Mac")
                } footer: {
                    Text(relay.paired
                         ? "Recordings go straight to your Mac when both are on the same Wi-Fi, encrypted with the pairing code. Each stays on this phone until the Mac has it."
                         : "Omi Import on your Mac shows the code in Setup, under Your phone.")
                }

                Section {
                    if relay.rows.isEmpty {
                        Text("Nothing yet. A recording appears here a minute after it ends.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(relay.rows) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.start.formatted(date: .abbreviated, time: .shortened))
                                Text(RecordingLayout.length(row.seconds)).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if row.waiting {
                                Text("On this phone").font(.callout).foregroundStyle(.secondary)
                            } else {
                                Label("On your Mac", systemImage: "checkmark")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.green)
                                    .accessibilityLabel("On your Mac")
                            }
                        }
                    }
                } header: {
                    Text(waitingHeader)
                }
            }
            .navigationTitle("Omi Relay")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: Paths.log) { Label("Share the log", systemImage: "doc.text") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { relay.syncNow() } label: { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") }
                }
            }
            .refreshable { relay.syncNow() }
            .confirmationDialog("Unpair from your Mac?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { relay.unpair() }
            } message: {
                Text("Recordings stay on this phone until you pair again.")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                relay.reload()
                relay.syncNow()
            }
        }
    }

    private var waitingHeader: String {
        let waiting = relay.waiting
        guard !waiting.isEmpty else { return "Recordings" }
        return "Recordings · \(waiting.count) waiting, \(formatBytes(waiting.map(\.bytes).reduce(0, +)))"
    }

    private func pair() {
        codeRefused = !relay.pair(code)
        if !codeRefused { code = "" }
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
