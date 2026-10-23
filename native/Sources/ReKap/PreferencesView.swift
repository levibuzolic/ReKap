import AppKit
import AVFoundation
import SwiftUI
import ReKapCore

struct PreferencesView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("Recording") {
                CaptureOptionsView(settings: model.settings, microphones: model.microphones)
                LabeledContent("Save recordings to") {
                    Text(model.settings.recordingDirectory).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { model.settings.recordingDirectory = url.path }
                    }
                }
            }
            Section("Global Shortcut") {
                Toggle("Enable global recording shortcut", isOn: $model.settings.shortcutEnabled)
                    .onChange(of: model.settings.shortcutEnabled) { model.updateShortcut() }
                LabeledContent("Start / stop recording") {
                    ShortcutRecorder(settings: model.settings) { model.updateShortcut() }
                        .frame(width: 165, height: 28)
                }
                Text("Click the shortcut field, then press a key with Command or Control. The shortcut opens capture setup when idle and stops an active recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("ReKap", value: "Native macOS · Apple silicon")
                Text("Original recordings stay in your recording folder. Removing a history entry never deletes its video.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).padding().frame(width: 610, height: 580)
        .onAppear { model.refreshMicrophones() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in model.refreshMicrophones() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in model.refreshMicrophones() }
    }
}

struct CaptureOptionsView: View {
    @Bindable var settings: AppSettings
    let microphones: [AVCaptureDevice]
    var audioLabel = "Record system audio"
    var body: some View {
        Picker("Frame rate", selection: $settings.fps) {
            Text("30 fps").tag(30)
            Text("60 fps").tag(60)
        }
        Toggle("Show cursor", isOn: $settings.showsCursor)
        Toggle("Highlight mouse clicks", isOn: $settings.highlightsClicks)
        Toggle("Record microphone", isOn: $settings.capturesMicrophone)
        if settings.capturesMicrophone {
            Picker("Microphone", selection: $settings.microphoneID) {
                Text("System Default").tag("")
                ForEach(microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
        }
        Toggle(audioLabel, isOn: $settings.capturesSystemAudio)
    }
}
