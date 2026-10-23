import Foundation
import Observation

@MainActor @Observable public final class AppSettings {
    private let defaults: UserDefaults
    public var fps: Int { didSet { defaults.set(fps, forKey: "fps") } }
    public var showsCursor: Bool { didSet { defaults.set(showsCursor, forKey: "showsCursor") } }
    public var highlightsClicks: Bool { didSet { defaults.set(highlightsClicks, forKey: "highlightsClicks") } }
    public var capturesMicrophone: Bool { didSet { defaults.set(capturesMicrophone, forKey: "capturesMicrophone") } }
    public var capturesSystemAudio: Bool { didSet { defaults.set(capturesSystemAudio, forKey: "capturesSystemAudio") } }
    public var microphoneID: String { didSet { defaults.set(microphoneID, forKey: "microphoneID") } }
    public private(set) var recordingDirectories: [String]
    public var recordingDirectory: String {
        didSet {
            defaults.set(recordingDirectory, forKey: "recordingDirectory")
            if !recordingDirectories.contains(recordingDirectory) {
                recordingDirectories.append(recordingDirectory)
                defaults.set(recordingDirectories, forKey: "recordingDirectories")
            }
        }
    }
    public var shortcutEnabled: Bool { didSet { defaults.set(shortcutEnabled, forKey: "shortcutEnabled") } }
    public var shortcutKeyCode: Int { didSet { defaults.set(shortcutKeyCode, forKey: "shortcutKeyCode") } }
    public var shortcutModifiers: Int { didSet { defaults.set(shortcutModifiers, forKey: "shortcutModifiers") } }
    public var shortcutLabel: String { didSet { defaults.set(shortcutLabel, forKey: "shortcutLabel") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "fps": 30, "showsCursor": true, "highlightsClicks": false,
            "capturesMicrophone": false, "capturesSystemAudio": false,
            "microphoneID": "", "shortcutEnabled": true, "shortcutKeyCode": 19,
            "shortcutModifiers": 768, "shortcutLabel": "⌘⇧2",
            "recordingDirectory": FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ReKap").path
        ])
        fps = defaults.integer(forKey: "fps") == 60 ? 60 : 30
        showsCursor = defaults.bool(forKey: "showsCursor")
        highlightsClicks = defaults.bool(forKey: "highlightsClicks")
        capturesMicrophone = defaults.bool(forKey: "capturesMicrophone")
        capturesSystemAudio = defaults.bool(forKey: "capturesSystemAudio")
        microphoneID = defaults.string(forKey: "microphoneID") ?? ""
        recordingDirectory = defaults.string(forKey: "recordingDirectory")!
        recordingDirectories = defaults.stringArray(forKey: "recordingDirectories") ?? []
        shortcutEnabled = defaults.bool(forKey: "shortcutEnabled")
        shortcutKeyCode = defaults.integer(forKey: "shortcutKeyCode")
        shortcutModifiers = defaults.integer(forKey: "shortcutModifiers")
        shortcutLabel = defaults.string(forKey: "shortcutLabel") ?? "⌘⇧2"
        if !recordingDirectories.contains(recordingDirectory) { recordingDirectories.append(recordingDirectory) }
    }

    public var captureOptions: CaptureOptions {
        var options = CaptureOptions()
        options.fps = fps
        options.showsCursor = showsCursor
        options.highlightsClicks = highlightsClicks
        options.capturesMicrophone = capturesMicrophone
        options.capturesSystemAudio = capturesSystemAudio
        options.microphoneID = microphoneID.isEmpty ? nil : microphoneID
        return options
    }
}
