import Foundation
import Testing
@testable import ReKapCore

struct CaptureAudioTests {
    @Test @MainActor func passthroughPreservesEveryFrameAndMixedAudioAcrossPauseBoundary() async throws {
        let encoder = try ExportArguments.findEncoder()
        let probe = ProcessInfo.processInfo.environment["REKAP_FFPROBE"].map { URL(fileURLWithPath: $0) }
            ?? encoder.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReKapCaptureAudio-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var sources: [URL] = []
        var sourceHashes: [String] = []
        for index in 0..<2 {
            let url = directory.appendingPathComponent("segment-\(index).mp4")
            // ScreenCaptureKit mixes microphone and system audio into one track.
            // Two known tones exercise that mixed AAC contract through assembly.
            _ = try run(encoder, ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x96:rate=60:duration=1",
                                  "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1",
                                  "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=1",
                                  "-filter_complex", "[1:a][2:a]amix=inputs=2:normalize=1[a]", "-map", "0:v", "-map", "[a]",
                                  "-c:v", "libx264", "-c:a", "aac", "-ar", "48000", "-shortest", url.path])
            let hashes = try frameHashes(encoder: encoder, url: url)
            #expect(hashes.count == 60)
            sourceHashes += hashes
            sources.append(url)
        }
        let final = try await CaptureAssembly.assemble(sources, in: directory)
        let finalHashes = try frameHashes(encoder: encoder, url: final)
        #expect(finalHashes == sourceHashes)

        let metadata = try run(probe, ["-v", "error", "-show_streams", "-of", "json", final.path])
        let object = try #require(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        let streams = try #require(object["streams"] as? [[String: Any]])
        let video = try #require(streams.first { $0["codec_type"] as? String == "video" })
        let audioTracks = streams.filter { $0["codec_type"] as? String == "audio" }
        #expect(audioTracks.count == 1)
        let audio = try #require(audioTracks.first)
        #expect(audio["codec_name"] as? String == "aac")
        #expect(audio["sample_rate"] as? String == "48000")
        let videoDuration = try #require(Double(video["duration"] as? String ?? ""))
        let audioDuration = try #require(Double(audio["duration"] as? String ?? ""))
        #expect(abs(videoDuration - 2) < 0.02)
        #expect(abs(audioDuration - videoDuration) < 0.05)

        let decoded = try run(encoder, ["-v", "error", "-i", final.path, "-map", "0:a:0", "-ac", "1", "-ar", "48000", "-f", "f32le", "-"])
        let samples: [Float] = decoded.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count - 3, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
        }
        #expect(samples.count >= 95_000)
        let join = Array(samples[45_600..<50_400]) // 100 ms spanning the one-second join.
        let rms = sqrt(join.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(join.count))
        #expect(rms > 0.025)
        // Both sources remain audible on either side of pause/resume.
        for start in [12_000, 60_000] {
            let window = Array(samples[start..<(start + 12_000)])
            for frequency in [440.0, 880.0] {
                let magnitude = toneMagnitude(window, frequency: frequency)
                #expect(magnitude > 0.015)
            }
        }
    }

    private func toneMagnitude(_ samples: [Float], frequency: Double) -> Double {
        var real = 0.0
        var imaginary = 0.0
        for (index, value) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(index) / 48_000
            real += Double(value) * cos(phase)
            imaginary -= Double(value) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(samples.count)
    }

    private func frameHashes(encoder: URL, url: URL) throws -> [String] {
        let data = try run(encoder, ["-v", "error", "-i", url.path, "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "framemd5", "-"])
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            return line.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Media subprocess failed: \(arguments.joined(separator: " "))")
        return result
    }
}
