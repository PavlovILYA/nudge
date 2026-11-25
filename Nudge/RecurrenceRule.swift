import Foundation

/// Calendar rules use the selected timezone and original wall-clock time.
/// Hours are elapsed intervals. Missing month days are skipped, never clamped.
struct RecurrenceRule: Codable, Equatable, Sendable {
    enum Unit: String, Codable, CaseIterable, Sendable { case hours, days, weeks, weekdays, months }
    var unit: Unit
    var interval = 1
    var weekdays: [Int] = [] // Calendar weekday: Sunday = 1.
    var monthDay: Int?
    var timeZoneID = TimeZone.current.identifier

    func validate() throws {
        guard (1...365).contains(interval), TimeZone(identifier: timeZoneID) != nil,
              monthDay.map({ (1...31).contains($0) }) ?? true else { throw RuleError.invalid }
        if unit == .weekdays {
            guard interval == 1, !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }) else { throw RuleError.invalid }
        }
    }
    func next(after date: Date, anchor: Date) throws -> Date {
        try validate()
        guard date.timeIntervalSince1970.isFinite, anchor.timeIntervalSince1970.isFinite, abs(date.timeIntervalSince1970) < 1e12, abs(anchor.timeIntervalSince1970) < 1e12 else { throw RuleError.invalid }
        if unit == .hours {
            if date < anchor { return anchor }
            let step = Double(interval) * 3600
            return anchor.addingTimeInterval(max(1, floor(date.timeIntervalSince(anchor) / step) + 1) * step)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID)!
        let clock = calendar.dateComponents([.hour, .minute, .second], from: anchor)
        func atClock(_ day: Date) -> Date? {
            calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: clock.second ?? 0,
                          of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
        }
        switch unit {
        case .days, .weeks:
            let stride = interval * (unit == .weeks ? 7 : 1)
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: anchor), to: calendar.startOfDay(for: date)).day ?? 0
            let slot = max(0, days / stride)
            for offset in slot...(slot + 2) {
                if let day = calendar.date(byAdding: .day, value: offset * stride, to: calendar.startOfDay(for: anchor)),
                   let candidate = atClock(day), candidate > date { return candidate }
            }
        case .weekdays:
            for offset in 0...7 {
                if let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: max(date, anchor))),
                   weekdays.contains(calendar.component(.weekday, from: day)),
                   let candidate = atClock(day), candidate > date, candidate >= anchor { return candidate }
            }
        case .months:
            let a = calendar.dateComponents([.year, .month, .day], from: anchor)
            let d = calendar.dateComponents([.year, .month], from: date)
            let delta = ((d.year ?? 0) - (a.year ?? 0)) * 12 + (d.month ?? 1) - (a.month ?? 1)
            let first = max(0, delta / interval)
            // A bounded Gregorian cycle, including impossible combinations such as
            // February 31 every 12 months. Never loop indefinitely on invalid data.
            for slot in first..<(first + 4800) {
                var components = DateComponents()
                components.year = a.year; components.month = (a.month ?? 1) + slot * interval; components.day = 1
                guard let month = calendar.date(from: components), let dayCount = calendar.range(of: .day, in: .month, for: month) else { continue }
                let day = monthDay ?? a.day ?? 1
                guard dayCount.contains(day), let target = calendar.date(byAdding: .day, value: day - 1, to: month),
                      let candidate = atClock(target), candidate > date else { continue }
                return candidate
            }
        case .hours: break
        }
        throw RuleError.noDate
    }

    func first(anchor: Date) throws -> Date {
        try validate()
        guard anchor.timeIntervalSince1970.isFinite, abs(anchor.timeIntervalSince1970) < 1e12 else { throw RuleError.invalid }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID)!
        if unit == .weekdays && !weekdays.contains(calendar.component(.weekday, from: anchor)) {
            return try next(after: anchor, anchor: anchor)
        }
        if unit == .months, let monthDay, monthDay != calendar.component(.day, from: anchor) {
            return try next(after: anchor, anchor: anchor)
        }
        return anchor
    }

    var title: String {
        switch unit {
        case .hours: return interval == 1 ? String(localized: "Hourly") : String(localized: "Every \(interval) hours")
        case .days: return interval == 1 ? String(localized: "Daily") : String(localized: "Every \(interval) days")
        case .weeks: return interval == 1 ? String(localized: "Weekly") : String(localized: "Every \(interval) weeks")
        case .weekdays:
            let names = Calendar.current.weekdaySymbols
            return Array(Set(weekdays)).sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }.joined(separator: ", ")
        case .months:
            if let monthDay {
                return interval == 1 ? String(localized: "Day \(monthDay) of each month") : String(localized: "Day \(monthDay), every \(interval) months")
            }
            return interval == 1 ? String(localized: "Monthly") : String(localized: "Every \(interval) months")
        }
    }
    enum RuleError: LocalizedError {
        case invalid, noDate
        var errorDescription: String? { String(localized: "Check the repeat interval, days and timezone.") }
    }
}

struct CompletedOccurrence: Codable, Equatable, Sendable {
    let id: UUID
    let dueAt: Date
    let completedAt: Date
}
