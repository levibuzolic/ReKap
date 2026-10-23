import AppKit
import SwiftUI
import ReKapCore

@main struct ReKapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("ReKap", id: "main") {
            LibraryView(model: model)
                .task {
                    delegate.model = model
                    await model.initialize()
                }
                .onOpenURL { model.importVideo($0) }
        }
        .defaultSize(width: 1080, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording…") { model.presentRecorder() }.keyboardShortcut("n")
                    .disabled(model.isBusy || model.isCapturing)
                Button("Open Video…") { model.importVideo() }.keyboardShortcut("o")
            }
        }
        Settings { PreferencesView(model: model) }
        Window("Exports", id: "exports") {
            ExportsView(exports: model.exports).frame(minWidth: 650, minHeight: 350)
        }.defaultSize(width: 740, height: 450)
        MenuBarExtra {
            RecordingMenu(model: model)
        } label: {
            Image(systemName: model.capture.state == .paused ? "pause.circle.fill" : model.isCapturing ? "record.circle.fill" : "record.circle")
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingFiles: [URL] = []
    weak var model: AppModel? {
        didSet {
            guard let model else { return }
            for url in pendingFiles { model.importVideo(url) }
            pendingFiles.removeAll()
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else { pendingFiles.append(contentsOf: urls); return }
        for url in urls { model.importVideo(url) }
        model.openMainWindow?()
        application.activate()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.openMainWindow?()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.isBusy || model.capture.state == .stopping { return .terminateCancel }
        guard confirmExportCancellation(model) else { return .terminateCancel }
        Task {
            if model.isCapturing { await model.stop() }
            if !model.isCapturing { await model.exports.cancelAllAndWait() }
            sender.reply(toApplicationShouldTerminate: !model.isCapturing)
        }
        return .terminateLater
    }

    private func confirmExportCancellation(_ model: AppModel) -> Bool {
        if model.activeExports > 0 {
            let alert = NSAlert()
            alert.messageText = "Exports are still running"
            alert.informativeText = "Quit and cancel unfinished exports?"
            alert.addButton(withTitle: "Keep Exporting")
            alert.addButton(withTitle: "Quit")
            return alert.runModal() == .alertSecondButtonReturn
        }
        return true
    }

}

private struct RecordingMenu: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if model.isCapturing {
            Text(model.capture.state == .paused ? "Recording Paused" : "Recording…")
            Button(model.capture.state == .paused ? "Resume" : "Pause") { Task { await model.pauseOrResume() } }
                .disabled(model.isBusy)
            Button("Stop Recording") {
                openWindow(id: "main")
                Task { await model.stop() }
            }.disabled(model.isBusy)
        } else {
            Button("New Recording…") {
                openWindow(id: "main")
                model.presentRecorder()
            }.disabled(model.isBusy)
        }
        Divider()
        Button("Show ReKap") { openWindow(id: "main"); NSApp.activate() }
        Button("Exports") { openWindow(id: "exports"); NSApp.activate() }
        SettingsLink()
        Divider()
        Button("Quit ReKap") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
