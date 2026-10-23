import AppKit
import SwiftUI
import ReKapCore

struct LibraryView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                Section("Recordings") {
                    ForEach(model.library.recordings) { recording in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(recording.title, systemImage: "film")
                                .lineLimit(2)
                            Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .tag(recording.id)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recording.url]) }
                            Button("Remove from History", role: .destructive) { model.remove(recording.id) }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 245, max: 340)
            .safeAreaInset(edge: .bottom) {
                Button { model.importVideo() } label: { Label("Open Video…", systemImage: "folder") }
                    .buttonStyle(.plain).padding().frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            if let recording = model.selectedRecording {
                EditorView(recording: recording, exports: model.exports).id(recording.id)
            } else {
                ContentUnavailableView {
                    Label("Ready when you are", systemImage: "record.circle")
                } description: {
                    Text("Record a region, display or window, or open a video to edit and export.")
                } actions: {
                    Button("New Recording…") { model.presentRecorder() }.buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.isCapturing)
                    Button("Open Video…") { model.importVideo() }
                }
            }
        }
        .frame(minWidth: 950, minHeight: 620)
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isCapturing {
                    Label(model.capture.elapsed.formatted(.number.precision(.fractionLength(0))) + "s",
                          systemImage: model.capture.state == .paused ? "pause.fill" : "record.circle.fill")
                        .foregroundStyle(.red).monospacedDigit().labelStyle(.titleAndIcon).fixedSize()
                    Button(model.capture.state == .paused ? "Resume" : "Pause", systemImage: model.capture.state == .paused ? "play.fill" : "pause.fill") {
                        Task { await model.pauseOrResume() }
                    }.disabled(model.isBusy)
                        .accessibilityLabel(model.capture.state == .paused ? "Resume Recording" : "Pause Recording")
                    Button("Stop", systemImage: "stop.fill") { Task { await model.stop() } }.disabled(model.isBusy)
                        .accessibilityLabel("Stop Recording")
                } else {
                    Button("New Recording", systemImage: "record.circle") { model.presentRecorder() }
                        .disabled(model.isBusy)
                }
            }
        }
        .sheet(isPresented: $model.showRecorder) { RecorderView(model: model) }
        .alert("ReKap", isPresented: Binding(get: { !model.showRecorder && (model.errorMessage != nil || model.capture.errorMessage != nil) }, set: { if !$0 { model.errorMessage = nil; model.capture.clearError() } })) {
            Button("OK") { model.errorMessage = nil; model.capture.clearError() }
        } message: { Text(model.errorMessage ?? model.capture.errorMessage ?? "") }
    }
}
