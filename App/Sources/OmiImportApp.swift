import AppKit
import OmiImportCore
import SwiftUI

@main
struct OmiImportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = ImportController.shared

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!Headless.on)) {
            MenuContent().environmentObject(controller)
        } label: {
            Image(systemName: controller.isTransferring ? "waveform.badge.plus" : "waveform")
        }
    }
}

/// A scripted run that must not be seen: no menu bar item, and a settings
/// window drawn for snapshots without being put on any screen. Debug builds only.
enum Headless {
    #if DEBUG
    static let on = ProcessInfo.processInfo.environment["OMI_IMPORT_HEADLESS"] == "1"
    #else
    static let on = false
    #endif
}

private struct MenuContent: View {
    @EnvironmentObject private var controller: ImportController

    var body: some View {
        Text("Phone: \(controller.phoneStatus ?? "Not listening")")
        if let cloud = controller.cloudStatus { Text("Cloud: \(cloud)") }
        if let last = controller.settings.lastImport {
            Text("Last arrival \(last.formatted(.relative(presentation: .named)))")
        }
        Divider()
        Button("Check Omi's Cloud") { controller.importNow() }
            .disabled(!controller.canImportNow)
        Button("Open Folder") { controller.openFolder() }
            .disabled(controller.settings.destination == nil)
        Button("Settings…") { AppDelegate.showSettings() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Omi Import") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // A debug build only ever runs against a folder of its own.
        guard Paths.isOverridden else {
            NSLog("Omi Import debug builds need OMI_IMPORT_HOME set. Exiting.")
            exit(0)
        }
        if let path = ProcessInfo.processInfo.environment["OMI_IMPORT_SNAPSHOT"] {
            Self.snapshotSettings(to: path)
            return
        }
        // OMI_IMPORT_ENGELBART=status|add with OMI_IMPORT_ENGELBART_FOLDER:
        // runs the library bridge once, prints what happened, and quits.
        if let command = ProcessInfo.processInfo.environment["OMI_IMPORT_ENGELBART"],
           let folder = ProcessInfo.processInfo.environment["OMI_IMPORT_ENGELBART_FOLDER"] {
            guard let install = Engelbart.detect() else { print("engelbart: not found"); exit(1) }
            print("library: \(install.library.path)")
            print("runtime: \(install.runtime.path)")
            print("open in: \(Engelbart.holders(of: install))")
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            print("can list: \(Engelbart.canList(url))")
            do {
                print("result: \(try Engelbart.run(command, folder: url, name: url.lastPathComponent, install: install))")
                exit(0)
            } catch {
                print("refused: \(error.localizedDescription)")
                exit(2)
            }
        }
        #endif
        let controller = ImportController.shared
        controller.start()
        if controller.settings.destination == nil { Self.showSettings() }
    }

    static func showSettings() {
        if settingsWindow == nil {
            let root = SettingsView().environmentObject(ImportController.shared)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Omi Import"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 820, height: 600))
            window.contentMinSize = NSSize(width: 700, height: 480)
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("OmiImportSettings")
            settingsWindow = window
        }
        if Headless.on {
            settingsWindow?.alphaValue = 0
            settingsWindow?.ignoresMouseEvents = true
            settingsWindow?.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            settingsWindow?.orderBack(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

#if DEBUG
extension AppDelegate {
    /// Draws the settings window into a PNG and quits, so a build can be
    /// looked at without anything appearing on screen.
    /// OMI_IMPORT_PANE=recordings picks the pane.
    static func snapshotSettings(to path: String) {
        ImportController.shared.loadForSnapshot()
        showSettings()
        if let height = ProcessInfo.processInfo.environment["OMI_IMPORT_HEIGHT"].flatMap(Double.init) {
            settingsWindow?.setContentSize(NSSize(width: 820, height: height))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let view = settingsWindow?.contentView?.superview ?? settingsWindow?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
#endif
