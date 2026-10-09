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
}
