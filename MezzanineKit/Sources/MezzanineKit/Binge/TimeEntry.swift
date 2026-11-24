import Foundation

/// A time typed into Go to Time: "1:02:30", "62:30" (minutes and seconds) or "62" (minutes).
public enum TimeEntry {
    public static func seconds(_ text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 4, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        // Only the first part may pass 59.
        guard numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        switch numbers.count {
        case 1: return Double(numbers[0] * 60)
        case 2: return Double(numbers[0] * 60 + numbers[1])
        default: return Double(numbers[0] * 3600 + numbers[1] * 60 + numbers[2])
        }
    }

    /// When a title ends by the clock, at this speed.
    public static func end(current: TimeInterval, duration: TimeInterval, rate: Double, now: Date = Date()) -> Date? {
        guard duration > 0, rate > 0 else { return nil }
        return now.addingTimeInterval(max(0, duration - current) / rate)
    }
}
