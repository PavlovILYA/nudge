import SwiftUI

struct RecurrencePicker: View {
    @Binding var rule: RecurrenceRule?
    @Binding var date: Date?
    @State private var custom = false
    private enum Mode: String, CaseIterable { case never, daily, weekly, monthly, custom
        var title: String {
            switch self {
            case .never: String(localized: "Never")
            case .daily: String(localized: "Daily")
            case .weekly: String(localized: "Weekly")
            case .monthly: String(localized: "Monthly")
            case .custom: String(localized: "Custom")
            }
        }
    }
    private var mode: Mode {
        guard let rule else { return .never }
        if custom || rule.interval != 1 || rule.monthDay != nil { return .custom }
        switch rule.unit { case .days: return .daily; case .weeks: return .weekly; case .months: return .monthly; default: return .custom }
    }
    var body: some View {
        Picker("Repeat", selection: Binding(get: { mode }, set: { value in
            custom = value == .custom
            if value == .never { rule = nil; return }
            if date == nil { date = .now.addingTimeInterval(3600) }
            rule = RecurrenceRule(unit: value == .weekly ? .weeks : value == .monthly ? .months : .days)
        })) { ForEach(Mode.allCases, id: \.self) { Text($0.title).tag($0) } }
        if rule != nil, mode == .custom {
            Picker("Repeat unit", selection: Binding(get: { rule?.unit ?? .days }, set: { value in
                rule?.unit = value
                rule?.interval = min(rule?.interval ?? 1, rule?.maximumInterval ?? 365)
                if value == .weekdays { rule?.interval = 1; rule?.weekdays = [Calendar.current.component(.weekday, from: date ?? .now)] }
            })) {
                Text("Minutes").tag(RecurrenceRule.Unit.minutes)
                Text("Hours").tag(RecurrenceRule.Unit.hours)
                Text("Days").tag(RecurrenceRule.Unit.days)
                Text("Weeks").tag(RecurrenceRule.Unit.weeks)
                Text("Selected weekdays").tag(RecurrenceRule.Unit.weekdays)
                Text("Months").tag(RecurrenceRule.Unit.months)
            }
            if rule?.unit == .weekdays {
                ForEach(1...7, id: \.self) { day in
                    Toggle(Calendar.current.weekdaySymbols[day - 1], isOn: Binding(get: { rule?.weekdays.contains(day) == true }, set: { enabled in
                        var days = rule?.weekdays ?? []
                        days.removeAll { $0 == day }; if enabled { days.append(day) }
                        rule?.weekdays = days.sorted()
                    }))
                }
            } else {
                Stepper("Interval: \(rule?.interval ?? 1)", value: Binding(get: { rule?.interval ?? 1 }, set: { rule?.interval = $0 }), in: 1...(rule?.maximumInterval ?? 365))
            }
            if rule?.unit == .months {
                Toggle("Specific day of month", isOn: Binding(get: { rule?.monthDay != nil }, set: { rule?.monthDay = $0 ? Calendar.current.component(.day, from: date ?? .now) : nil }))
                if rule?.monthDay != nil {
                    Stepper("Day: \(rule?.monthDay ?? 1)", value: Binding(get: { rule?.monthDay ?? 1 }, set: { rule?.monthDay = $0 }), in: 1...31)
                }
            }
        }
        if let rule {
            Text(rule.title).font(.caption).foregroundStyle(.secondary)
            Text("System Stop completes one occurrence and schedules the next. Done in Nudge finishes the series. Missed occurrences do not trigger new alarms.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
