import Foundation

/// Converts between the 0.0-1.0 scalar used by CoreAudio and whole percents.
/// All comparisons are done on rounded whole percents so tiny float differences never
/// cause a write (and therefore never cause a notification feedback loop).
public enum VolumeMath {
    public static let minLevel = 0
    public static let maxLevel = 100

    public static func isValidLevel(_ level: Int) -> Bool { (minLevel...maxLevel).contains(level) }

    public static func toPercent(_ scalar: Float32) -> Int {
        if scalar.isNaN { return 0 }
        let clamped = Double(min(max(scalar, 0), 1))
        return Int((clamped * 100).rounded(.toNearestOrAwayFromZero))
    }

    /// Precondition: `isValidLevel(percent)`.
    public static func toScalar(_ percent: Int) -> Float32 {
        precondition(isValidLevel(percent), "Level \(percent) is outside 0-100.")
        return Float32(percent) / 100
    }

    public static func clampScalar(_ scalar: Float32) -> Float32 {
        if scalar.isNaN { return 0 }
        return min(max(scalar, 0), 1)
    }
}
