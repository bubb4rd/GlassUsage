import Foundation

enum Format {
    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// "950", "12.3K", "281M", "4.07B".
    static func tokens(_ count: Int) -> String {
        func trimmed(_ value: Double) -> String {
            let text = String(format: "%.1f", value)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return trimmed(Double(count) / 1e3) + "K"
        case ..<1_000_000_000: return trimmed(Double(count) / 1e6) + "M"
        default: return String(format: "%.2fB", Double(count) / 1e9)
        }
    }

    /// "$41.86", "$1,631.53".
    static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// Time left: "12m", "2h 14m", "3d 4h", "now".
    static func until(_ date: Date, now: Date) -> String {
        var seconds = Int(date.timeIntervalSince(now).rounded())
        if seconds <= 0 { return "now" }
        let days = seconds / 86_400
        seconds -= days * 86_400
        let hours = seconds / 3600
        let minutes = (seconds - hours * 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    /// Age of a reading: "just now", "40s ago", "3m ago", "2h ago", "4d ago".
    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        let seconds = max(0, Int(now.timeIntervalSince(date).rounded()))
        switch seconds {
        case ..<10: return "just now"
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    /// Full reset time for tooltips: "Today at 2:00 AM", "Fri at 2:00 PM", "Nov 29 at 2:00 PM".
    static func clock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        let day = date.timeIntervalSince(now) < 6.5 * 86_400
            ? date.formatted(.dateTime.weekday(.abbreviated))
            : date.formatted(.dateTime.month(.abbreviated).day())
        return "\(day) \(time)"
    }
}

extension UsageWindow {
    /// Row label in the limits list: "5h", "week", "month".
    var shortLabel: String {
        switch key {
        case "session": duration > 0 ? "\(Int((duration / 3600).rounded()))h" : "session"
        case "weekly": "week"
        case "monthly": "month"
        default: title.lowercased()
        }
    }
}
