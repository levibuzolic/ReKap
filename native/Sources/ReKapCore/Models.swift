import Foundation

public enum ExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case gif, apng, h264, hevc, webm, av1
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .gif: "GIF"
        case .apng: "APNG"
        case .h264: "MP4 (H.264)"
        case .hevc: "MP4 (HEVC)"
        case .webm: "WebM"
        case .av1: "MP4 (AV1)"
        }
    }
    public var fileExtension: String {
        switch self {
        case .gif: "gif"
        case .apng: "png"
        case .webm: "webm"
        default: "mp4"
        }
    }
}

public struct Recording: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var url: URL
    public var title: String
    public var createdAt: Date
    public init(id: UUID = UUID(), url: URL, title: String, createdAt: Date = .now) {
        self.id = id
        self.url = url
        self.title = title
        self.createdAt = createdAt
    }
}

public struct ExportRequest: Sendable {
    public var inputURL: URL
    public var outputURL: URL
    public var format: ExportFormat
    public var startTime: Double
    public var endTime: Double
    public var width: Int
    public var height: Int
    public var fps: Int
    public var muted: Bool
    public var loop: Bool
    public var lossyGIF: Bool
    public init(inputURL: URL, outputURL: URL, format: ExportFormat, startTime: Double,
                endTime: Double, width: Int, height: Int, fps: Int, muted: Bool = false,
                loop: Bool = true, lossyGIF: Bool = false) {
        self.inputURL = inputURL; self.outputURL = outputURL; self.format = format
        self.startTime = startTime; self.endTime = endTime
        self.width = width; self.height = height; self.fps = fps
        self.muted = muted; self.loop = loop; self.lossyGIF = lossyGIF
    }
}

public struct CaptureOptions: Sendable {
    public var fps = 30
    public var showsCursor = true
    public var highlightsClicks = false
    public var capturesMicrophone = false
    public var microphoneID: String?
    public var capturesSystemAudio = false
    public init() {}
}
