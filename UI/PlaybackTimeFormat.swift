import Foundation

/// Tiempo de reproducción: "23:02" bajo una hora y "1:02:03" desde una hora.
enum PlaybackTimeFormat {
    static func string(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
