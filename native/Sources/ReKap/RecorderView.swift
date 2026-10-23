import AppKit
import SwiftUI
import ReKapCore

struct RecorderView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("New Recording").font(.title2.bold())
            if let error = model.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    Button("Open Screen Recording Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }
            Picker("Capture", selection: $model.sourceMode) {
                ForEach(AppModel.SourceMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if model.sourceMode == .window {
                Picker("Window", selection: $model.selectedWindowID) {
                    Text("Choose a window").tag(Optional<UInt32>.none)
                    ForEach(model.capture.windows, id: \.windowID) { window in
                        Text("\(window.owningApplication?.applicationName ?? "App") — \(window.title ?? "Untitled")")
                            .tag(Optional(window.windowID))
                    }
                }
            } else {
                Picker("Display", selection: $model.selectedDisplayID) {
                    Text("Choose a display").tag(Optional<UInt32>.none)
                    ForEach(model.capture.displays, id: \.displayID) { display in
                        Text("Display \(display.displayID) · \(display.width) × \(display.height)")
                            .tag(Optional(display.displayID))
                    }
                }
                if model.sourceMode == .region {
                    Text("Next, drag to select a region on the chosen display. Press Escape to cancel.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            CaptureOptionsView(settings: model.settings, microphones: model.microphones,
                               audioLabel: model.sourceMode == .window ? "Record app audio" : "Record system audio")
            HStack {
                Button("Refresh Sources", systemImage: "arrow.clockwise") { Task { await model.refreshSources() } }
                Spacer()
                Button("Cancel") { model.errorMessage = nil; model.showRecorder = false }.keyboardShortcut(.cancelAction)
                Button(model.sourceMode == .region ? "Select Region…" : "Start Recording") { Task { await model.start() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || (model.sourceMode == .window ? model.selectedWindowID == nil : model.selectedDisplayID == nil))
            }
        }
        .padding(28).frame(width: 540)
        .task { await model.refreshSources() }
    }
}
