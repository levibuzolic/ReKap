import AppKit
import ReKapCore
import SwiftUI
import UniformTypeIdentifiers

struct ExportsView: View {
    let exports: ExportManager
    @State private var actionError: String?

    var body: some View {
        Group {
            if exports.jobs.isEmpty {
                ContentUnavailableView("No exports yet", systemImage: "square.and.arrow.up", description: Text("Open a recording and choose Export to save a copy."))
            } else {
                List {
                    ForEach(exports.jobs.reversed()) { job in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: job.status == .completed ? "checkmark.circle.fill" : "film")
                                    .foregroundStyle(job.status == .completed ? Color.green : Color.secondary)
                                Text(job.request.outputURL.lastPathComponent).font(.headline).lineLimit(1)
                                Spacer()
                                Text(job.status.rawValue.capitalized).foregroundStyle(.secondary)
                            }
                            Text("\(job.request.format.title) · \(job.request.width) × \(job.request.height) · \(job.request.fps) fps")
                                .font(.caption).foregroundStyle(.secondary)
                            if job.status == .running || job.status == .queued {
                                HStack {
                                    ProgressView(value: job.progress).accessibilityLabel("Export progress")
                                    Text(job.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                                    Button("Cancel") { exports.cancel(job.id) }
                                }
                            }
                            if let error = job.errorMessage {
                                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            }
                            if job.status == .completed {
                                HStack {
                                    Button("Show in Finder", systemImage: "folder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([job.request.outputURL])
                                    }
                                    Button("Copy", systemImage: "doc.on.doc") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.writeObjects([job.request.outputURL as NSURL])
                                    }.help("Copy exported file to clipboard")
                                    Button("Open", systemImage: "arrow.up.forward.app") {
                                        if !NSWorkspace.shared.open(job.request.outputURL) {
                                            actionError = "No application could open this export. Use Open With to select an application."
                                        }
                                    }
                                    Button("Open With…") { openWith(job.request.outputURL) }
                                }.controlSize(.small)
                            }
                            if job.status == .failed || job.status == .cancelled {
                                Button("Retry", systemImage: "arrow.clockwise") { _ = exports.enqueue(job.request) }
                                    .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .contain)
                    }
                }
            }
        }
        .alert("Unable to open export", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: { Text(actionError ?? "") }
    }

    private func openWith(_ file: URL) {
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let application = panel.url else { return }
        NSWorkspace.shared.open([file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Task { @MainActor in actionError = error.localizedDescription }
            }
        }
    }
}
