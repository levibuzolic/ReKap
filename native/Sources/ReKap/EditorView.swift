import AppKit
import AVKit
import ReKapCore
import SwiftUI
import UniformTypeIdentifiers

/// A single-source editor. All edits are applied on export; source recordings stay intact.
struct EditorView: View {
    let recording: Recording
    let exports: ExportManager
    @State private var player = AVPlayer()
    @State private var trim = EditorTrimRange(duration: 0)
    private var duration: Double { trim.duration }
    private var start: Double {
        get { trim.start }
        nonmutating set { trim.setStart(newValue) }
    }
    private var end: Double {
        get { trim.end }
        nonmutating set { trim.setEnd(newValue) }
    }
    private var effectiveMute: Bool { muted || format == .gif || format == .apng }
    @State private var position = 0.0
    @State private var sourceWidth = 1
    @State private var sourceHeight = 1
    @State private var width = 1280
    @State private var height = 720
    @State private var linked = true
    @State private var fps = 30
    @State private var muted = false
    @State private var format = ExportFormat.h264
    @State private var loop = true
    @State private var lossyGIF = false
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var showingQueue = false

    private var valid: Bool {
        trim.isValid && end - start <= 86_400 &&
        width >= 2 && height >= 2 && width <= 8192 && height <= 8192 &&
        ([ExportFormat.gif, .apng].contains(format) || (width.isMultiple(of: 2) && height.isMultiple(of: 2)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                preview.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inspector.frame(width: 300).fixedSize(horizontal: false, vertical: false)
            }
            Divider()
            HStack {
                Label(recording.title, systemImage: "film")
                    .lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                Spacer()
                Button("Exports", systemImage: "list.bullet.rectangle") { showingQueue = true }
                Button("Export…", systemImage: "square.and.arrow.up", action: export)
                    .keyboardShortcut("e", modifiers: .command)
                    .buttonStyle(.borderedProminent).fixedSize().disabled(!valid || loading)
            }.padding()
        }
        .navigationTitle(recording.title)
        .task(id: recording.id) { await load() }
        .task {
            while !Task.isCancelled {
                position = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
                if player.rate != 0 && position >= end && end > 0 {
                    player.pause()
                    seek(start)
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        .onDisappear { player.pause() }
        .onChange(of: effectiveMute) { _, value in player.isMuted = value }
        .sheet(isPresented: $showingQueue) {
            VStack {
                ExportsView(exports: exports)
                HStack { Spacer(); Button("Done") { showingQueue = false }.keyboardShortcut(.defaultAction) }.padding()
            }.frame(minWidth: 620, minHeight: 320)
        }
        .alert("Unable to edit recording", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var preview: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black
                EditorPlayerView(player: player)
                if loading { ProgressView("Loading recording…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) }
            }.clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Button(action: togglePlayback) {
                    Image(systemName: player.rate == 0 ? "play.fill" : "pause.fill")
                }.help("Play or pause (Space)")
                Slider(value: Binding(get: { min(max(position, 0), max(duration, 0.01)) }, set: { seek($0) }), in: 0...max(duration, 0.01))
                    .accessibilityLabel("Playback position")
                Text("\(time(position)) / \(time(duration))")
                    .font(.system(.caption, design: .monospaced)).monospacedDigit()
            }.disabled(loading || duration <= 0)
            Text("Space to play or pause · Arrow keys to seek one second")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .focusable()
        .onKeyPress(.space) { togglePlayback(); return .handled }
        .onKeyPress(.leftArrow) { seek(max(start, position - 1)); return .handled }
        .onKeyPress(.rightArrow) { seek(min(end, position + 1)); return .handled }
    }

    private var inspector: some View {
        Form {
            Section("Trim") {
                HStack {
                    Text("Start").frame(width: 38, alignment: .leading)
                    TextField("Seconds", value: Binding(get: { start }, set: { start = $0; seek(start) }), format: .number.precision(.fractionLength(2)))
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 50, maxWidth: .infinity)
                        .accessibilityLabel("Trim start in seconds")
                    Text("s").foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { start }, set: { start = $0; seek(start) }), in: 0...max(duration, 0.01))
                    .accessibilityLabel("Trim start")
                HStack {
                    Text("End").frame(width: 38, alignment: .leading)
                    TextField("Seconds", value: Binding(get: { end }, set: { end = $0; seek(max(start, end - 0.1)) }), format: .number.precision(.fractionLength(2)))
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 50, maxWidth: .infinity)
                        .accessibilityLabel("Trim end in seconds")
                    Text("s").foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { end }, set: { end = $0; seek(max(start, end - 0.1)) }), in: 0...max(duration, 0.01))
                    .accessibilityLabel("Trim end")
                if end - start > 86_400 {
                    Text("Choose a range of up to 24 hours for export.").font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text("\(time(max(0, end - start))) selected").foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { trim.reset(); seek(0) }
                }.font(.caption)
            }
            Section("Size") {
                HStack {
                    TextField("Width", value: Binding(get: { width }, set: { width = $0; if linked { height = even(Double($0) * Double(sourceHeight) / Double(sourceWidth)) } }), format: .number.grouping(.never))
                        .frame(minWidth: 45, maxWidth: .infinity)
                        .accessibilityLabel("Export width in pixels")
                    Text("×")
                    TextField("Height", value: Binding(get: { height }, set: { height = $0; if linked { width = even(Double($0) * Double(sourceWidth) / Double(sourceHeight)) } }), format: .number.grouping(.never))
                        .frame(minWidth: 45, maxWidth: .infinity)
                        .accessibilityLabel("Export height in pixels")
                    Text("px").foregroundStyle(.secondary)
                }
                Toggle("Keep aspect ratio", isOn: $linked)
                HStack {
                    ForEach([100, 75, 50, 25], id: \.self) { percent in
                        Button("\(percent)%") {
                            width = even(Double(sourceWidth) * Double(percent) / 100)
                            height = even(Double(sourceHeight) * Double(percent) / 100)
                        }.controlSize(.small)
                    }
                }
                if width < 2 || height < 2 || width > 8192 || height > 8192 {
                    Text("Dimensions must be between 2 and 8,192 pixels.").font(.caption).foregroundStyle(.red)
                }
                if ![ExportFormat.gif, .apng].contains(format) && (!width.isMultiple(of: 2) || !height.isMultiple(of: 2)) {
                    Text("Video dimensions must be even numbers.").font(.caption).foregroundStyle(.red)
                }
            }
            Section("Export") {
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                }
                Picker("Frame rate", selection: $fps) {
                    ForEach(EditorFrameRates.supported, id: \.self) { Text("\($0) fps").tag($0) }
                }
                Toggle("Mute audio", isOn: Binding(get: { effectiveMute }, set: { muted = $0 }))
                    .disabled(format == .gif || format == .apng)
                if format == .gif || format == .apng { Toggle("Loop animation", isOn: $loop) }
                if format == .gif { Toggle("Smaller GIF (lossy)", isOn: $lossyGIF) }
                Text("The original recording is preserved.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .disabled(loading || duration <= 0)
    }

    private func load() async {
        player.pause()
        loading = true
        trim = EditorTrimRange(duration: 0)
        player.replaceCurrentItem(with: nil)
        errorMessage = nil
        defer { loading = false }
        do {
            let asset = AVURLAsset(url: recording.url)
            let assetDuration = try await asset.load(.duration).seconds
            guard assetDuration.isFinite, assetDuration > 0 else { throw EditorError.invalidDuration }
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EditorError.noVideo }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let displaySize = size.applying(transform)
            guard displaySize.width.isFinite, displaySize.height.isFinite,
                  abs(displaySize.width) >= 1, abs(displaySize.height) >= 1,
                  abs(displaySize.width) <= 65536, abs(displaySize.height) <= 65536 else {
                throw EditorError.invalidDimensions
            }
            let rate = try await track.load(.nominalFrameRate)
            try Task.checkCancellation()
            sourceWidth = max(2, Int(abs(displaySize.width).rounded()))
            sourceHeight = max(2, Int(abs(displaySize.height).rounded()))
            width = even(Double(sourceWidth)); height = even(Double(sourceHeight))
            trim = EditorTrimRange(duration: assetDuration)
            fps = EditorFrameRates.preferred(for: rate)
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            player.isMuted = effectiveMute
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    private func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        position = seconds
    }

    private func togglePlayback() {
        guard !loading, trim.isValid else { return }
        if player.rate != 0 { player.pause() }
        else {
            if position < start || position >= end { seek(start) }
            player.play()
        }
    }

    private func export() {
        guard valid else { return }
        player.pause()
        let panel = NSSavePanel()
        panel.title = "Export recording"
        panel.nameFieldStringValue = URL(fileURLWithPath: recording.title).deletingPathExtension().lastPathComponent + "." + format.fileExtension
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard destination.standardizedFileURL != recording.url.standardizedFileURL else {
            errorMessage = "Choose a different filename to preserve the original recording."
            return
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "Choose a new filename. Existing files are preserved."
            return
        }
        _ = exports.enqueue(ExportRequest(inputURL: recording.url, outputURL: destination, format: format,
                                          startTime: start, endTime: end, width: width, height: height,
                                          fps: fps, muted: effectiveMute, loop: loop, lossyGIF: lossyGIF))
        showingQueue = true
    }

    private func even(_ value: Double) -> Int {
        guard value.isFinite else { return 2 }
        return max(2, Int(min(8192, max(2, value))) / 2 * 2)
    }

    private func time(_ value: Double) -> String {
        guard value.isFinite else { return "0:00.00" }
        let safe = min(Double(Int.max / 2), max(0, value))
        return String(format: "%d:%05.2f", Int(safe) / 60, safe.truncatingRemainder(dividingBy: 60))
    }
}

private enum EditorError: LocalizedError {
    case invalidDuration, noVideo, invalidDimensions
    var errorDescription: String? {
        switch self {
        case .invalidDuration: "This recording has no playable duration."
        case .noVideo: "This file does not contain a video track."
        case .invalidDimensions: "This file has invalid or unsupported video dimensions."
        }
    }
}


/// Use AVKit's AppKit view directly. SwiftUI's VideoPlayer cross-import overlay
/// can fail superclass lookup in a standalone SwiftPM app bundle.
private struct EditorPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
