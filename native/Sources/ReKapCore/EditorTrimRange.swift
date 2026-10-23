import Foundation

/// Keeps text entry and scrubbing inside a finite, nonempty media range.
/// Nonfinite edits are ignored, retaining the last usable selection.
public struct EditorTrimRange: Equatable, Sendable {
    public let duration: Double
    public private(set) var start: Double
    public private(set) var end: Double

    public init(duration: Double) {
        self.duration = duration.isFinite && duration > 0 ? duration : 0
        start = 0
        end = self.duration
    }

    public var isValid: Bool { duration > 0 && start >= 0 && end <= duration && end > start }
    private var minimumLength: Double { min(0.01, duration) }

    public mutating func setStart(_ value: Double) {
        guard value.isFinite else { return }
        start = min(max(0, value), max(0, end - minimumLength))
    }

    public mutating func setEnd(_ value: Double) {
        guard value.isFinite else { return }
        end = min(duration, max(start + minimumLength, value))
    }

    public mutating func reset() { start = 0; end = duration }
}

public enum EditorFrameRates {
    public static let supported = [10, 15, 24, 25, 30, 50, 60]

    /// Avoid silently reducing frames when a variable-rate recording averages
    /// below its capture target. Allow small nominal-rate rounding differences.
    public static func preferred(for nominal: Float) -> Int {
        guard nominal.isFinite, nominal > 0 else { return 30 }
        return supported.first(where: { Double($0) + 0.01 >= Double(nominal) }) ?? 60
    }
}
