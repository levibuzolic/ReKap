import AVFoundation
import Foundation
import Darwin
import Observation

public enum ExportStatus: String, Sendable {
    case queued, running, completed, cancelled, failed
}

@MainActor @Observable public final class ExportJob: Identifiable {
    public let id = UUID()
    public let request: ExportRequest
    public fileprivate(set) var progress = 0.0
    public fileprivate(set) var status: ExportStatus = .queued
    public fileprivate(set) var errorMessage: String?
    fileprivate init(request: ExportRequest) { self.request = request }
}

public enum ExportError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

/// Executes one encode at a time to keep capture responsive and bound memory usage.
@MainActor @Observable public final class ExportManager {
    public private(set) var jobs: [ExportJob] = []
    private let encoderURL: URL?
    private var worker: ExportProcess?
    private var processing = false

    public init(encoderURL: URL? = nil) { self.encoderURL = encoderURL }

    @discardableResult public func enqueue(_ request: ExportRequest) -> UUID {
        let job = ExportJob(request: request)
        jobs.append(job)
        processNext()
        return job.id
    }

    public func cancel(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }),
              job.status == .queued || job.status == .running else { return }
        let wasRunning = job.status == .running
        job.status = .cancelled
        if wasRunning { worker?.cancel() }
    }

    /// Cancel the complete queue and wait until the encoder has exited and temporary
    /// files have been removed before allowing the application to terminate.
    public func cancelAllAndWait() async {
        for job in jobs where job.status == .queued || job.status == .running { cancel(job.id) }
        while processing { try? await Task.sleep(for: .milliseconds(25)) }
    }

    private func processNext() {
        guard !processing, let job = jobs.first(where: { $0.status == .queued }) else { return }
        processing = true
        job.status = .running
        let process = ExportProcess()
        worker = process
        Task {
            do {
                try ExportArguments.validate(job.request)
                let asset = AVURLAsset(url: job.request.inputURL)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, job.request.endTime <= duration + 0.05 else {
                    throw ExportError.invalid("The trim range exceeds the source duration.")
                }
                guard job.status != .cancelled else { throw CancellationError() }
                let executable = try encoderURL ?? ExportArguments.findEncoder()
                let request = job.request
                let progress: @Sendable (Double) -> Void = { fraction in
                    Task { @MainActor in
                        if job.status == .running { job.progress = max(job.progress, min(0.99, fraction)) }
                    }
                }
                try await Task.detached(priority: .userInitiated) {
                    try process.run(executable: executable, request: request, progress: progress)
                }.value
                if job.status != .cancelled { job.progress = 1; job.status = .completed }
            } catch {
                if job.status != .cancelled {
                    job.status = .failed
                    job.errorMessage = error.localizedDescription
                }
            }
            worker = nil
            processing = false
            processNext()
        }
    }
}

public enum ExportArguments {
    public static func findEncoder() throws -> URL {
        // Packaged apps must use the signed helper, never a user's PATH executable.
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        if Bundle.main.bundleURL.pathExtension == "app" {
            throw ExportError.invalid("The bundled FFmpeg encoder is missing. Rebuild the app with its encoder helpers.")
        }
        let candidates = [ProcessInfo.processInfo.environment["REKAP_FFMPEG"],
                          "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ExportError.invalid("FFmpeg is missing. Install FFmpeg or set REKAP_FFMPEG for development.")
        }
        return URL(fileURLWithPath: path)
    }

    public static func validate(_ request: ExportRequest) throws {
        guard request.inputURL.isFileURL, request.outputURL.isFileURL else {
            throw ExportError.invalid("Export requires local files.")
        }
        guard request.inputURL.resolvingSymlinksInPath().standardizedFileURL != request.outputURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw ExportError.invalid("Choose a destination different from the source recording.")
        }
        guard !FileManager.default.fileExists(atPath: request.outputURL.path) else {
            throw ExportError.invalid("The destination already exists. Choose a new filename.")
        }
        guard FileManager.default.isReadableFile(atPath: request.inputURL.path) else {
            throw ExportError.invalid("The source recording cannot be read.")
        }
        guard request.startTime.isFinite, request.endTime.isFinite,
              request.startTime >= 0, request.endTime > request.startTime,
              request.endTime - request.startTime <= 86_400 else {
            throw ExportError.invalid("Choose a valid trim range of up to 24 hours.")
        }
        guard (2...8192).contains(request.width), (2...8192).contains(request.height),
              (1...60).contains(request.fps) else {
            throw ExportError.invalid("Dimensions must be 2–8192 pixels and frame rate 1–60 fps.")
        }
        if ![ExportFormat.gif, .apng].contains(request.format), request.width % 2 != 0 || request.height % 2 != 0 {
            throw ExportError.invalid("Video export dimensions must be even numbers.")
        }
    }

    public static func paletteArguments(for r: ExportRequest, paletteURL: URL) -> [String] {
        ["-hide_banner", "-nostdin", "-n", "-loglevel", "error", "-progress", "pipe:1",
         "-ss", String(r.startTime), "-t", String(r.endTime - r.startTime), "-i", r.inputURL.path,
         "-vf", "fps=\(r.fps),scale=\(r.width):\(r.height):flags=lanczos,palettegen=max_colors=\(r.lossyGIF ? 64 : 256):stats_mode=diff",
         "-frames:v", "1", "-an", "-update", "1", paletteURL.path]
    }

    public static func arguments(for r: ExportRequest, temporaryOutput: URL, paletteURL: URL? = nil) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-n", "-loglevel", "error", "-progress", "pipe:1", "-stats_period", "0.1",
                    "-ss", String(r.startTime), "-t", String(r.endTime - r.startTime), "-i", r.inputURL.path]
        let filter = "fps=\(r.fps),scale=\(r.width):\(r.height):flags=lanczos,setsar=1"
        if r.format == .gif, let paletteURL {
            // The first pass generates a global palette. Reading it as a second
            // input avoids buffering every video frame while waiting for EOF.
            args += ["-i", paletteURL.path, "-filter_complex", "[0:v]\(filter)[v];[v][1:v]paletteuse=dither=sierra2_4a[out]", "-map", "[out]", "-an", "-loop", r.loop ? "0" : "-1", "-f", "gif"]
        } else {
            args += ["-map", "0:v:0", "-vf", filter]
            if r.format == .apng {
                args += ["-an", "-c:v", "apng", "-plays", r.loop ? "0" : "1", "-f", "apng"]
            } else {
                args += ["-pix_fmt", "yuv420p"]
                if r.muted { args += ["-an"] }
                else { args += ["-map", "0:a:0?", "-c:a", r.format == .webm ? "libopus" : "aac", "-b:a", "128k"] }
                switch r.format {
                case .h264: args += ["-c:v", "libx264", "-preset", "fast", "-crf", "20"]
                case .hevc: args += ["-c:v", "libx265", "-preset", "fast", "-crf", "24", "-tag:v", "hvc1", "-x265-params", "pools=2:frame-threads=2:log-level=error"]
                case .webm: args += ["-c:v", "libvpx-vp9", "-crf", "30", "-b:v", "0", "-deadline", "good", "-cpu-used", "4"]
                case .av1: args += ["-c:v", "libsvtav1", "-crf", "32", "-preset", "10", "-svtav1-params", "lp=2"]
                default: break
                }
                args += ["-threads", "2"]
                if r.format == .webm { args += ["-f", "webm"] }
                else { args += ["-movflags", "+faststart", "-f", "mp4"] }
            }
        }
        args.append(temporaryOutput.path)
        return args
    }
}

private final class ExportProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let active = process
        if let active, active.isRunning { active.terminate() }
        lock.unlock()
    }

    func run(executable: URL, request: ExportRequest, progress: @Sendable (Double) -> Void) throws {
        let directory = request.outputURL.deletingLastPathComponent()
        // Temporary output lives on the destination filesystem for atomic delivery.
        let temporary = directory.appendingPathComponent(".rekap-\(UUID().uuidString).partial")
        let palette = directory.appendingPathComponent(".rekap-\(UUID().uuidString).palette.png")
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("rekap-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: log)
        defer {
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: palette)
            try? FileManager.default.removeItem(at: log)
        }
        if request.format == .gif {
            try launch(executable: executable, arguments: ExportArguments.paletteArguments(for: request, paletteURL: palette),
                       errorHandle: errorHandle, log: log, duration: request.endTime - request.startTime,
                       progress: { progress(min(0.2, $0 * 0.2)) })
            progress(0.2)
        }
        try launch(executable: executable,
                   arguments: ExportArguments.arguments(for: request, temporaryOutput: temporary,
                                                        paletteURL: request.format == .gif ? palette : nil),
                   errorHandle: errorHandle, log: log, duration: request.endTime - request.startTime,
                   progress: { progress(request.format == .gif ? 0.2 + $0 * 0.8 : $0) })
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            // Exclusive rename publishes only a complete file, refusing to replace
            // anything created at the destination since validation completed.
            guard renamex_np(temporary.path, request.outputURL.path, UInt32(RENAME_EXCL)) == 0 else {
                throw ExportError.invalid("Could not deliver the export: \(String(cString: strerror(errno))). Choose a writable, unused filename.")
            }
        }
    }
    private func launch(executable: URL, arguments: [String], errorHandle: FileHandle, log: URL,
                        duration: Double, progress: @Sendable (Double) -> Void) throws {
        let output = Pipe()
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.standardOutput = output
        child.standardError = errorHandle
        var launched = false
        defer {
            // Reading the progress pipe can itself fail. Every exit path must
            // reap the child before the queue advances or shutdown completes.
            if launched {
                if child.isRunning {
                    child.terminate()
                    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while child.isRunning, ContinuousClock.now < deadline {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
                child.waitUntilExit()
            }
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            lock.withLock {
                if process === child { process = nil }
            }
        }
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            process = child
            try child.run()
            launched = true
        }
        var pending = ""
        while let data = try output.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
            pending += String(decoding: data, as: UTF8.self)
            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newline])
                pending.removeSubrange(...newline)
                if line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst(12)) {
                    progress(micros / 1_000_000 / duration)
                }
            }
        }
        child.waitUntilExit()
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            guard child.terminationStatus == 0 else {
                let data = (try? Data(contentsOf: log)) ?? Data()
                let detail = String(decoding: data.suffix(4096), as: UTF8.self)
                throw ExportError.invalid("FFmpeg export failed (\(child.terminationStatus)). \(detail)")
            }
        }
    }

}
