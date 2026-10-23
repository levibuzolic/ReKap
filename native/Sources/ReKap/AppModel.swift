import AppKit
import AVFoundation
import Observation
import ReKapCore
import ScreenCaptureKit

@MainActor @Observable final class AppModel {
    let capture = CaptureEngine()
    let exports = ExportManager()
    let library = LibraryStore()
    var settings = AppSettings()
    var selectedID: UUID?
    var errorMessage: String?
    var isBusy = false
    var showRecorder = false
    var sourceMode = SourceMode.region
    var selectedDisplayID: CGDirectDisplayID?
    var selectedWindowID: CGWindowID?
    var microphones: [AVCaptureDevice] = []
    private var shortcut: GlobalShortcut?
    var openMainWindow: (() -> Void)?
    private var initialized = false

    enum SourceMode: String, CaseIterable, Identifiable {
        case region = "Region", display = "Display", window = "Window"
        var id: String { rawValue }
    }

    var selectedRecording: Recording? { library.recordings.first { $0.id == selectedID } }
    var isCapturing: Bool { capture.state != .idle }
    var activeExports: Int { exports.jobs.filter { $0.status == .queued || $0.status == .running }.count }

    func initialize() async {
        guard !initialized else { return }
        initialized = true
        isBusy = true
        defer { isBusy = false }
        shortcut = GlobalShortcut { [weak self] in self?.toggleRecorder() }
        updateShortcut()
        refreshMicrophones()
        errorMessage = library.errorMessage
        // Recover only our own session directories; importing never moves source media.
        for directory in settings.recordingDirectories {
            let recovered = await capture.recoverSessions(in: URL(fileURLWithPath: directory))
            for url in recovered {
                do { try library.add(url: url, recovered: true) } catch { errorMessage = error.localizedDescription }
            }
        }
        if selectedID == nil { selectedID = library.recordings.first?.id }
    }

    func updateShortcut() {
        do {
            try shortcut?.register(enabled: settings.shortcutEnabled,
                                   keyCode: UInt32(settings.shortcutKeyCode),
                                   modifiers: UInt32(settings.shortcutModifiers))
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleRecorder() {
        if capture.state == .recording || capture.state == .paused {
            Task { await stop() }
        } else { presentRecorder() }
    }

    func presentRecorder() {
        guard !isBusy, !isCapturing else { return }
        openMainWindow?()
        showRecorder = true
        NSApp.activate()
    }

    func refreshMicrophones() {
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        if !settings.microphoneID.isEmpty && !microphones.contains(where: { $0.uniqueID == settings.microphoneID }) {
            settings.microphoneID = ""
        }
    }

    func refreshSources() async {
        errorMessage = nil
        refreshMicrophones()
        do {
            try await capture.refreshSources()
            if !capture.displays.contains(where: { $0.displayID == selectedDisplayID }) {
                selectedDisplayID = capture.displays.first(where: { $0.displayID == CGMainDisplayID() })?.displayID ?? capture.displays.first?.displayID
            }
            if !capture.windows.contains(where: { $0.windowID == selectedWindowID }) {
                selectedWindowID = capture.windows.first?.windowID
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func start() async {
        guard !isBusy, capture.state == .idle else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let directory = URL(fileURLWithPath: settings.recordingDirectory, isDirectory: true)
            if sourceMode == .window {
                guard let window = capture.windows.first(where: { $0.windowID == selectedWindowID }) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Choose a window to record."])
                }
                showRecorder = false
                try await capture.start(window: window, options: settings.captureOptions, directory: directory)
            } else {
                guard let display = capture.displays.first(where: { $0.displayID == selectedDisplayID }) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Choose a display to record."])
                }
                var region: CGRect?
                showRecorder = false
                if sourceMode == .region {
                    // Let SwiftUI finish dismissing the sheet before the overlay takes focus.
                    try await Task.sleep(for: .milliseconds(250))
                    region = await RegionSelector.select(on: display)
                    guard region != nil else { return }
                }
                try await capture.start(display: display, region: region, options: settings.captureOptions, directory: directory)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func pauseOrResume() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if capture.state == .recording { try await capture.pause() }
            else if capture.state == .paused { try await capture.resume() }
        } catch { errorMessage = error.localizedDescription }
    }

    func stop() async {
        guard !isBusy, capture.state == .recording || capture.state == .paused else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let url = try await capture.stop()
            let title = "Recording \(Date.now.formatted(date: .abbreviated, time: .standard))"
            try library.add(url: url, title: title)
            selectedID = library.recordings.first(where: { $0.url == url })?.id
            NSApp.activate()
            NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "ReKap" })?.makeKeyAndOrderFront(nil)
        } catch { errorMessage = error.localizedDescription }
    }

    func importVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { importVideo(url) }
    }

    func importVideo(_ url: URL) {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            errorMessage = "Choose a readable video file on this Mac."
            return
        }
        do {
            try library.add(url: url)
            selectedID = library.recordings.first(where: { $0.url == url })?.id
        } catch { errorMessage = error.localizedDescription }
    }

    func remove(_ id: UUID) {
        do {
            try library.remove([id])
            if selectedID == id { selectedID = library.recordings.first?.id }
        } catch { errorMessage = error.localizedDescription }
    }
}
