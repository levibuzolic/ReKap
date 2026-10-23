import AVFoundation
import Testing
@testable import ReKapCore

struct CaptureTests {
    @Test func regionValidationRejectsOutsideAndNonfiniteValues() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(CaptureGeometry.isValid(CGRect(x: 100, y: 100, width: 640, height: 360), within: bounds))
        #expect(!CaptureGeometry.isValid(CGRect(x: -1, y: 0, width: 640, height: 360), within: bounds))
        #expect(!CaptureGeometry.isValid(CGRect(x: 1200, y: 0, width: 640, height: 360), within: bounds))
        #expect(!CaptureGeometry.isValid(CGRect(x: 0, y: 0, width: 0, height: 1), within: bounds))
        #expect(!CaptureGeometry.isValid(CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 20), within: bounds))
        #expect(CaptureGeometry.evenPixels(641) == 640)
        #expect(CaptureGeometry.evenPixels(1280) == 1280)
    }

    @Test @MainActor func invalidTransitionsDoNotStartCapture() async throws {
        let engine = CaptureEngine()
        do { try await engine.pause(); Issue.record("Pause should reject idle") } catch { #expect(error is CaptureError) }
        do { try await engine.resume(); Issue.record("Resume should reject idle") } catch { #expect(error is CaptureError) }
        do { _ = try await engine.stop(); Issue.record("Stop should reject idle") } catch { #expect(error is CaptureError) }
        #expect(engine.state == .idle)
    }

    @Test @MainActor func recoverySkipsUnreadableAndCompletedManifests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("broken".utf8).write(to: root.appendingPathComponent("not-a-session"))
        let folder = root.appendingPathComponent("Session-complete")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(CaptureManifest(completed: true)).write(to: folder.appendingPathComponent("session.json"))
        let engine = CaptureEngine()
        let result = await engine.recoverSessions(in: root)
        #expect(result.isEmpty)
        #expect(engine.errorMessage == nil)
    }

    @Test @MainActor func assemblyConcatenatesSegmentsAndRecoveryIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = root.appendingPathComponent("Session-test")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = session.appendingPathComponent("segment-0.mp4")
        try await makeClip(at: source)
        let second = session.appendingPathComponent("segment-1.mp4")
        try FileManager.default.copyItem(at: source, to: second)
        let manifest = CaptureManifest(segmentNames: ["segment-0.mp4", "interrupted.mp4", "segment-1.mp4"])
        try JSONEncoder().encode(manifest).write(to: session.appendingPathComponent("session.json"))
        let engine = CaptureEngine()
        let recovered = await engine.recoverSessions(in: root)
        #expect(recovered.count == 1)
        let url = try #require(recovered.first)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(duration > 1.8 && duration < 2.2)
        let repeated = await engine.recoverSessions(in: root)
        #expect(repeated == recovered)
        #expect(FileManager.default.fileExists(atPath: source.path))
        // Healthy originals repair an unreadable final without deleting the damaged file.
        try Data("truncated mp4".utf8).write(to: url)
        let repaired = await engine.recoverSessions(in: root)
        #expect(repaired == recovered)
        let repairedDuration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(repairedDuration > 1.8 && repairedDuration < 2.2)
        let files = try FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)
        #expect(files.contains { $0.lastPathComponent.hasPrefix("Unreadable-") })
    }

    @Test @MainActor func sixtyFPSAndVariableTimingSurviveAssemblyAndRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cfr = (0..<120).map { CMTime(value: Int64($0), timescale: 60) }
        let variable: [CMTime] = (0..<90).map { index in
            let ticks: Int = index < 60 ? index : 60 + (index - 60) * 2
            return CMTime(value: Int64(ticks), timescale: 60)
        }
        let cases: [(String, [CMTime], Bool)] = [("60fps", cfr, false), ("variable", variable, false), ("reordered", variable, true)]
        for (name, timestamps, reordered) in cases {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = folder.appendingPathComponent("segment-0.mp4")
            try await makeClip(at: source, times: timestamps, reordered: reordered)
            let sourceTimes = try await frameTimes(at: source)
            #expect(sourceTimes.count == timestamps.count)
            let sourceDuration = try await AVURLAsset(url: source).load(.duration).seconds
            let single = try await CaptureAssembly.assemble([source], in: folder)
            #expect(try Data(contentsOf: single) == Data(contentsOf: source))
            #expect(try await frameTimes(at: single) == sourceTimes)
            try FileManager.default.removeItem(at: single)
            let next = folder.appendingPathComponent("segment-1.mp4")
            try FileManager.default.copyItem(at: source, to: next)
            let record = CaptureManifest(segmentNames: ["segment-0.mp4", "segment-1.mp4"])
            try JSONEncoder().encode(record).write(to: folder.appendingPathComponent("session.json"))
            let engine = CaptureEngine()
            let recovered = await engine.recoverSessions(in: root)
            let final = try #require(recovered.first { $0.deletingLastPathComponent().lastPathComponent == folder.lastPathComponent })
            let finalTimes = try await frameTimes(at: final)
            #expect(finalTimes.count == sourceTimes.count * 2)
            let finalDuration = try await AVURLAsset(url: final).load(.duration).seconds
            #expect(abs(finalDuration - sourceDuration * 2) < 0.002)
            // Both halves retain the variable intervals, as well as all frames.
            for index in sourceTimes.indices {
                #expect(abs(finalTimes[index] - sourceTimes[index]) < 0.002)
                let actualSecondTime = finalTimes[index + sourceTimes.count]
                if reordered {
                    // Compressed B-frame PTS include decoder offsets from each MP4
                    // edit. Compare intervals; the asset timeline duration above
                    // verifies those edits still join to the same playback length.
                    let actualInterval = actualSecondTime - finalTimes[sourceTimes.count]
                    let sourceInterval = sourceTimes[index] - sourceTimes[0]
                    #expect(abs(actualInterval - sourceInterval) < 0.002)
                } else {
                    let expectedSecondTime = sourceTimes[index] + sourceDuration
                    #expect(abs(actualSecondTime - expectedSecondTime) < 0.002)
                }
            }
        }
    }

    @MainActor private func frameTimes(at url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let provider = reader.outputProvider(for: output)
        try reader.start()
        var times: [Double] = []
        while let buffer = try await provider.next() {
            if buffer.sampleCount > 0, buffer.presentationTimeStamp.isNumeric {
                times.append(buffer.presentationTimeStamp.seconds)
            }
        }
        #expect(reader.status == .completed)
        return times.sorted()
    }

    @MainActor private func makeClip(at url: URL, times: [CMTime]? = nil, reordered: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64, AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: reordered, AVVideoExpectedSourceFrameRateKey: 60]])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: .init(rawValue: kCVPixelFormatType_32ARGB), size: .init(width: 64, height: 64))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for time in times ?? (0..<30).map({ CMTime(value: Int64($0), timescale: 30) }) {
            var pixel = try CVMutablePixelBuffer(attributes)
            pixel.accessUnsafeMutableRawPlaneBytes { planes in
                for plane in planes { plane.bytes.initializeMemory(as: UInt8.self, repeating: 128) }
            }
            try await receiver.append(CVReadOnlyPixelBuffer(pixel), with: time)
        }
        receiver.finish()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
