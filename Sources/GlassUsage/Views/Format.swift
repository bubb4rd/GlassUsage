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

    /// Reset time: "Today 2:00 AM", "Tomorrow 2:00 AM", "Fri 2:00 PM", "Nov 29 2:00 PM".
    /// `compact` trades words for width where a tag can't fit: "Tue 2:00 AM" for tomorrow, "Nov 29" past a week.
    static func clock(_ date: Date, now: Date, compact: Bool = false, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if !compact, let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        if date.timeIntervalSince(now) < 6.5 * 86_400 {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        return compact ? day : "\(day) \(time)"
    }

    /// A projected time to the nearest hour: "today ~4 PM", "Wed ~4 PM", "Nov 29 ~4 PM". `spoken` writes it out
    /// for VoiceOver: "today 4 PM", "Wednesday 4 PM".
    static func hour(_ date: Date, now: Date, spoken: Bool = false, calendar: Calendar = .current) -> String {
        let hour = calendar.dateInterval(of: .hour, for: date.addingTimeInterval(1800))?.start ?? date
        let day = if calendar.isDate(hour, inSameDayAs: now) {
            "today"
        } else if hour.timeIntervalSince(now) < 6.5 * 86_400 {
            hour.formatted(.dateTime.weekday(spoken ? .wide : .abbreviated))
        } else {
            hour.formatted(.dateTime.month(spoken ? .wide : .abbreviated).day())
        }
        return "\(day) \(spoken ? "" : "~")\(hour.formatted(.dateTime.hour()))"
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
