import Foundation
import XCTest
@testable import ReKapCore

final class ExportTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReKapExportTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let result = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        return result
    }

    func testValidationProtectsSourceAndRejectsUnboundedSettings() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        try Data("source".utf8).write(to: source)
        var request = ExportRequest(inputURL: source, outputURL: source, format: .h264,
                                    startTime: 0, endTime: 1, width: 160, height: 96, fps: 30)
        XCTAssertThrowsError(try ExportArguments.validate(request))
        request.outputURL = directory.appendingPathComponent("output.mp4")
        request.startTime = .nan
        XCTAssertThrowsError(try ExportArguments.validate(request))
        request.startTime = 0
        request.width = 161
        XCTAssertThrowsError(try ExportArguments.validate(request))
        request.width = 160
        request.fps = 120
        XCTAssertThrowsError(try ExportArguments.validate(request))
        request.fps = 30
        XCTAssertNoThrow(try ExportArguments.validate(request))
        try Data("keep".utf8).write(to: request.outputURL)
        XCTAssertThrowsError(try ExportArguments.validate(request))
        XCTAssertEqual(try Data(contentsOf: request.outputURL), Data("keep".utf8))
    }

    @MainActor private func waitForCompletion(_ manager: ExportManager, timeout: Duration = .seconds(60)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while manager.jobs.contains(where: { $0.status == .queued || $0.status == .running }) {
            guard clock.now < deadline else {
                for job in manager.jobs { manager.cancel(job.id) }
                XCTFail("Export exceeded timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor func testAllSixFormatsEncodeDecodableTrimmedResizedMedia() async throws {
        let encoder = try ExportArguments.findEncoder()
        let probe = ProcessInfo.processInfo.environment["REKAP_FFPROBE"].map { URL(fileURLWithPath: $0) }
            ?? encoder.deletingLastPathComponent().appendingPathComponent("ffprobe")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: probe.path), "Media integration tests require ffprobe beside ffmpeg")
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        _ = try run(encoder, ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x192:rate=30:duration=1.2",
                              "-f", "lavfi", "-i", "sine=frequency=440:duration=1.2", "-c:v", "libx264", "-c:a", "aac", "-shortest", source.path])
        let manager = ExportManager(encoderURL: encoder)
        for format in ExportFormat.allCases {
            manager.enqueue(ExportRequest(inputURL: source, outputURL: directory.appendingPathComponent("\(format.rawValue).\(format.fileExtension)"),
                                          format: format, startTime: 0.2, endTime: 1, width: 160, height: 96,
                                          fps: 10, muted: format == .hevc, loop: false, lossyGIF: true))
        }
        try await waitForCompletion(manager)
        let expectedCodecs: [ExportFormat: String] = [.gif: "gif", .apng: "apng", .h264: "h264", .hevc: "hevc", .webm: "vp9", .av1: "av1"]
        for job in manager.jobs {
            XCTAssertEqual(job.status, .completed, "\(job.request.format): \(job.errorMessage ?? "")")
            guard job.status == .completed else { continue }
            XCTAssertEqual(job.progress, 1)
            let data = try run(probe, ["-v", "error", "-show_streams", "-show_format", "-of", "json", job.request.outputURL.path])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let streams = try XCTUnwrap(json["streams"] as? [[String: Any]])
            let video = try XCTUnwrap(streams.first(where: { $0["codec_type"] as? String == "video" }))
            XCTAssertEqual(video["codec_name"] as? String, expectedCodecs[job.request.format])
            XCTAssertEqual(video["width"] as? Int, 160)
            XCTAssertEqual(video["height"] as? Int, 96)
            if [.h264, .av1, .webm].contains(job.request.format) {
                XCTAssertTrue(streams.contains(where: { $0["codec_type"] as? String == "audio" }))
            } else {
                XCTAssertFalse(streams.contains(where: { $0["codec_type"] as? String == "audio" }))
            }
            if let format = json["format"] as? [String: Any], let value = format["duration"] as? String, let duration = Double(value) {
                XCTAssertEqual(duration, 0.8, accuracy: 0.16)
            }
            _ = try run(encoder, ["-v", "error", "-i", job.request.outputURL.path, "-f", "null", "-"])
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.contains("partial") }))
    }

    @MainActor func testCancellationAndFailedJobDoNotBlockQueueOrLeavePartialOutput() async throws {
        let encoder = try ExportArguments.findEncoder()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        _ = try run(encoder, ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x192:duration=2", "-c:v", "libx264", source.path])
        let manager = ExportManager(encoderURL: encoder)
        let cancelledURL = directory.appendingPathComponent("cancelled.mp4")
        let id = manager.enqueue(ExportRequest(inputURL: source, outputURL: cancelledURL, format: .av1,
                                               startTime: 0, endTime: 2, width: 4096, height: 4096, fps: 60))
        try await Task.sleep(for: .milliseconds(150))
        manager.cancel(id)
        let invalidID = manager.enqueue(ExportRequest(inputURL: source, outputURL: source, format: .h264,
                                                     startTime: 0, endTime: 1, width: 160, height: 96, fps: 10))
        let successID = manager.enqueue(ExportRequest(inputURL: source, outputURL: directory.appendingPathComponent("success.mp4"), format: .h264,
                                                     startTime: 0, endTime: 1, width: 160, height: 96, fps: 10))
        try await waitForCompletion(manager)
        XCTAssertEqual(manager.jobs.first(where: { $0.id == id })?.status, .cancelled)
        XCTAssertEqual(manager.jobs.first(where: { $0.id == invalidID })?.status, .failed)
        XCTAssertEqual(manager.jobs.first(where: { $0.id == successID })?.status, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledURL.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.contains("partial") }))
    }
    @MainActor func testShutdownCancelsQueuedAndRunningGIFAndCleansBothPasses() async throws {
        let encoder = try ExportArguments.findEncoder()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        _ = try run(encoder, ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x192:duration=2", "-c:v", "libx264", source.path])
        let manager = ExportManager(encoderURL: encoder)
        for index in 0...1 {
            manager.enqueue(ExportRequest(inputURL: source, outputURL: directory.appendingPathComponent("out-\(index).gif"),
                                          format: .gif, startTime: 0, endTime: 2, width: 1920, height: 1080, fps: 30))
        }
        try await Task.sleep(for: .milliseconds(100))
        await manager.cancelAllAndWait()
        XCTAssertTrue(manager.jobs.allSatisfy { $0.status == .cancelled })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source.mp4"])
    }

}
