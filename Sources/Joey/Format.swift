import Foundation

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Int) -> String {
        bytesPerSecond < 1024 ? "–" : bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        return formatter.string(from: seconds) ?? ""
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(value < 1 ? 1 : 0)))
    }

    /// When a file was added: "Today", "Yesterday", "8 Oct", or "8 Oct 2025" for other years.
    static func added(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = calendar.isDate(date, equalTo: .now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year())
    }

    /// Playback time like "4:05" or "1:02:09".
    static func time(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(Int(seconds), 0) : 0
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
