import AppKit
import AVFoundation
import Observation
import ScreenCaptureKit

public enum CaptureState: String, Sendable { case idle, recording, paused, stopping }

public enum CaptureError: LocalizedError {
    case invalidState, invalidRegion, noFrames, finalizationTimedOut, screenAccessDenied
    public var errorDescription: String? {
        switch self {
        case .invalidState: "The recording is not ready for that action."
        case .screenAccessDenied: "Allow ReKap in System Settings → Privacy & Security → Screen & System Audio Recording, then refresh sources. If macOS asks you to quit and reopen ReKap, do so before trying again."
        case .invalidRegion: "Choose a region at least 2 points wide and high within the display."
        case .noFrames: "No playable recording segments were found."
        case .finalizationTimedOut: "The recording did not finish writing. Its session has been kept for recovery."
        }
    }
}

struct CaptureManifest: Codable {
    var segmentNames: [String] = []
    var completed = false
}

@MainActor @Observable
public final class CaptureEngine {
    public private(set) var state: CaptureState = .idle
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var errorMessage: String?
    public private(set) var displays: [SCDisplay] = []
    public private(set) var windows: [SCWindow] = []
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var delegate: CaptureDelegate?
    private var sessionDirectory: URL?
    private var manifest = CaptureManifest()
    private var timer: Task<Void, Never>?
    private var segmentStart: Date?
    private var accumulated: TimeInterval = 0
    private var busy = false
    public init() {}

    public func clearError() { errorMessage = nil }

    public func refreshSources() async throws {
        do {
            // ScreenCaptureKit requests authorization itself on first use. Do not issue a
            // second CoreGraphics permission request alongside its system prompt.
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            displays = content.displays
            windows = content.windows.filter { $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width > 1 && $0.frame.height > 1 && $0.windowLayer == 0 }
        } catch {
            displays = []; windows = []
            let underlying = error as NSError
            if underlying.domain == SCStreamErrorDomain, underlying.code == SCStreamError.Code.userDeclined.rawValue {
                throw CaptureError.screenAccessDenied
            }
            throw error
        }
    }

    public func start(display: SCDisplay, region: CGRect? = nil, options: CaptureOptions, directory: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let bounds = CGRect(origin: .zero, size: filter.contentRect.size)
        let rect = region ?? bounds
        guard CaptureGeometry.isValid(rect, within: bounds) else { throw CaptureError.invalidRegion }
        let config = makeConfiguration(options: options)
        let scale = CGFloat(filter.pointPixelScale)
        config.sourceRect = rect
        config.width = CaptureGeometry.evenPixels(rect.width * scale)
        config.height = CaptureGeometry.evenPixels(rect.height * scale)
        try await begin(filter: filter, configuration: config, directory: directory, options: options)
    }

    public func start(window: SCWindow, options: CaptureOptions, directory: URL) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = makeConfiguration(options: options)
        config.width = CaptureGeometry.evenPixels(window.frame.width * CGFloat(filter.pointPixelScale))
        config.height = CaptureGeometry.evenPixels(window.frame.height * CGFloat(filter.pointPixelScale))
        try await begin(filter: filter, configuration: config, directory: directory, options: options)
    }

    private func makeConfiguration(options: CaptureOptions) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: options.fps == 60 ? 60 : 30)
        config.showsCursor = options.showsCursor
        config.showMouseClicks = options.highlightsClicks
        config.capturesAudio = options.capturesSystemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = options.capturesMicrophone
        config.microphoneCaptureDeviceID = options.microphoneID
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        return config
    }

    private func begin(filter: SCContentFilter, configuration: SCStreamConfiguration, directory: URL, options: CaptureOptions) async throws {
        guard state == .idle, !busy else { throw CaptureError.invalidState }
        busy = true
        defer { busy = false }
        if options.capturesMicrophone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw NSError(domain: "ReKap", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone."]) }
        }
        self.filter = filter; self.configuration = configuration
        sessionDirectory = directory.appendingPathComponent("Session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory!, withIntermediateDirectories: true)
        manifest = CaptureManifest(); accumulated = 0; elapsed = 0; errorMessage = nil
        try saveManifest()
        do { try await startSegment(); state = .recording } catch { errorMessage = error.localizedDescription; throw error }
    }

    private func startSegment() async throws {
        guard let filter, let configuration, let sessionDirectory else { throw CaptureError.invalidState }
        let name = "segment-\(manifest.segmentNames.count).mp4"
        manifest.segmentNames.append(name)
        try saveManifest()
        let delegate = CaptureDelegate()
        delegate.onFailure = { [weak self, weak delegate] error in
            guard let self, let delegate, self.delegate === delegate else { return }
            self.errorMessage = error.localizedDescription
            self.timer?.cancel()
            if let started = self.segmentStart { self.accumulated += Date.now.timeIntervalSince(started) }
            self.segmentStart = nil; self.elapsed = self.accumulated
            if self.state == .recording { self.state = .paused }
            if let stream = self.stream { Task { try? await stream.stopCapture() } }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = sessionDirectory.appendingPathComponent(name)
        outputConfig.videoCodecType = .h264
        outputConfig.outputFileType = .mp4
        outputConfig.mixesAudioWithMicrophone = true
        let output = SCRecordingOutput(configuration: outputConfig, delegate: delegate)
        try stream.addRecordingOutput(output)
        self.delegate = delegate; self.stream = stream; self.recordingOutput = output
        do { try await stream.startCapture() } catch {
            try? await stream.stopCapture()
            self.stream = nil; self.recordingOutput = nil; self.delegate = nil
            throw error
        }
        if let failure = delegate.failure {
            try? await stream.stopCapture()
            self.stream = nil; self.recordingOutput = nil; self.delegate = nil
            throw failure
        }
        segmentStart = .now
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.elapsed = self.accumulated + (self.segmentStart.map { Date.now.timeIntervalSince($0) } ?? 0)
            }
        }
    }

    private func finishSegment() async throws {
        timer?.cancel(); timer = nil
        if let segmentStart { accumulated += Date.now.timeIntervalSince(segmentStart) }
        segmentStart = nil; elapsed = accumulated
        guard let stream, let delegate else { return }
        defer { self.stream = nil; recordingOutput = nil; self.delegate = nil }
        do { try await stream.stopCapture() } catch {
            if delegate.failure == nil { throw error }
        }
        let deadline = Date.now.addingTimeInterval(20)
        while !delegate.finished, delegate.failure == nil, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if let failure = delegate.failure { throw failure }
        guard delegate.finished else { throw CaptureError.finalizationTimedOut }
    }

    public func pause() async throws {
        guard state == .recording, !busy else { throw CaptureError.invalidState }
        busy = true; defer { busy = false }
        do { try await finishSegment(); state = .paused } catch { state = .paused; errorMessage = error.localizedDescription; throw error }
    }
    public func resume() async throws {
        guard state == .paused, !busy else { throw CaptureError.invalidState }
        busy = true; defer { busy = false }
        do {
            if stream != nil { try await finishSegment() }
            try await startSegment(); state = .recording
        } catch { errorMessage = error.localizedDescription; throw error }
    }
    public func stop() async throws -> URL {
        guard state == .recording || state == .paused, !busy, let sessionDirectory else { throw CaptureError.invalidState }
        busy = true; let wasRecording = state == .recording; state = .stopping
        defer { busy = false; state = .idle }
        do {
            if wasRecording || stream != nil { try await finishSegment() }
            let url = try await CaptureAssembly.assemble(manifest.segmentNames.map { sessionDirectory.appendingPathComponent($0) }, in: sessionDirectory)
            manifest.completed = true; try saveManifest()
            return url
        } catch { errorMessage = error.localizedDescription; throw error }
    }
    private func saveManifest() throws {
        guard let sessionDirectory else { throw CaptureError.invalidState }
        try JSONEncoder().encode(manifest).write(to: sessionDirectory.appendingPathComponent("session.json"), options: .atomic)
    }

    public func recoverSessions(in directory: URL) async -> [URL] {
        var recovered: [URL] = []
        for folder in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            let manifestURL = folder.appendingPathComponent("session.json")
            guard folder != sessionDirectory || state == .idle,
                  let data = try? Data(contentsOf: manifestURL),
                  var record = try? JSONDecoder().decode(CaptureManifest.self, from: data) else { continue }
            if record.completed {
                let final = folder.appendingPathComponent("Recording.mp4")
                guard FileManager.default.fileExists(atPath: final.path) else { continue }
                do {
                    recovered.append(try await CaptureAssembly.assemble(record.segmentNames.map { folder.appendingPathComponent($0) }, in: folder))
                } catch { errorMessage = "Could not recover \(folder.path): \(error.localizedDescription) Original segments remain in that folder." }
                continue
            }
            do {
                let result = try await CaptureAssembly.assemble(record.segmentNames.map { folder.appendingPathComponent($0) }, in: folder)
                record.completed = true
                try JSONEncoder().encode(record).write(to: manifestURL, options: .atomic)
                recovered.append(result)
            } catch { errorMessage = "Could not recover \(folder.path): \(error.localizedDescription) Original segments remain in that folder." }
        }
        return recovered
    }
}

@MainActor private final class CaptureDelegate: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    var finished = false
    var failure: Error?
    var onFailure: ((Error) -> Void)?
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { Task { @MainActor in self.finished = true } }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { Task { @MainActor in self.failure = error; self.onFailure?(error) } }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) { Task { @MainActor in self.failure = error; self.onFailure?(error) } }
}

public enum CaptureGeometry {
    public static func evenPixels(_ points: CGFloat) -> Int { max(2, Int(points.rounded()) / 2 * 2) }
    public static func isValid(_ rect: CGRect, within bounds: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite && rect.width >= 2 && rect.height >= 2 && bounds.contains(rect)
    }
}

@MainActor enum CaptureAssembly {
    static func assemble(_ segments: [URL], in directory: URL) async throws -> URL {
        let final = directory.appendingPathComponent("Recording.mp4")
        let replacingInvalidFinal = FileManager.default.fileExists(atPath: final.path)
        if replacingInvalidFinal {
            let existing = AVURLAsset(url: final)
            if let duration = try? await existing.load(.duration), duration.isNumeric, duration > .zero,
               let tracks = try? await existing.load(.tracks), tracks.contains(where: { $0.mediaType == .video }) {
                return final
            }
        }
        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        var playableSegments: [URL] = []
        var trackMap: [Int: AVMutableCompositionTrack] = [:]
        for url in segments {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration), duration.isNumeric, duration > .zero,
                  let tracks = try? await asset.load(.tracks), tracks.contains(where: { $0.mediaType == .video }) else { continue }
            playableSegments.append(url)
            var audioIndex = 0
            for track in tracks where track.mediaType == .video || track.mediaType == .audio {
                let key = track.mediaType == .video ? 0 : { audioIndex += 1; return audioIndex }()
                let destination: AVMutableCompositionTrack
                if let existing = trackMap[key] { destination = existing } else {
                    guard let added = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    destination = added; trackMap[key] = added
                    if track.mediaType == .video { destination.preferredTransform = try await track.load(.preferredTransform) }
                }
                let timeRange = try await track.load(.timeRange)
                let range = CMTimeRangeGetIntersection(timeRange, otherRange: CMTimeRange(start: .zero, duration: duration))
                if range.duration > .zero {
                    try destination.insertTimeRange(range, of: track, at: cursor + range.start)
                }
            }
            cursor = cursor + duration
        }
        guard cursor > .zero else { throw CaptureError.noFrames }
        let temporary = directory.appendingPathComponent("assembling-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        if playableSegments.count == 1 {
            // Preserve every compressed sample, timestamp and audio track. The source
            // remains available for recovery; publishing the copy is atomic below.
            try FileManager.default.copyItem(at: playableSegments[0], to: temporary)
        } else {
            // A quality preset silently converts ScreenCaptureKit's variable frame
            // timing to a lower constant rate. Passthrough retains original samples.
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw CaptureError.noFrames }
            do { try await exporter.export(to: temporary, as: .mp4) } catch {
                throw NSError(domain: "ReKap", code: 2, userInfo: [NSLocalizedDescriptionKey: "Recording segments could not be combined without changing captured frames. Original segments remain in \(directory.path). \(error.localizedDescription)"])
            }
        }
        if replacingInvalidFinal {
            _ = try FileManager.default.replaceItemAt(final, withItemAt: temporary, backupItemName: "Unreadable-\(UUID().uuidString).mp4", options: .withoutDeletingBackupItem)
        } else {
            try FileManager.default.moveItem(at: temporary, to: final)
        }
        return final
    }
}
