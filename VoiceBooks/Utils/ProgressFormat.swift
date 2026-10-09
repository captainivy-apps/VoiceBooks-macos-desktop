import Foundation

enum ProgressFormat {
    /// Formats a 0.0–1.0 ratio as "(xx.xx%)".
    static func percentSuffix(_ ratio: Float) -> String {
        String(format: "(%.2f%%)", min(max(ratio, 0), 1) * 100)
    }

    /// Formats current/total as "(xx.xx%)".
    static func percentSuffix(_ current: Int, _ total: Int) -> String {
        percentSuffix(Float(current) / Float(max(total, 1)))
    }
}
