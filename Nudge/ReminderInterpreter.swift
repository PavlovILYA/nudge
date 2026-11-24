import Foundation

struct InterpretationContext: Sendable {
    let now: Date
    var calendar: Calendar
    let timeZone: TimeZone
    let locale: Locale
    var defaultSoundID = AlarmSound.newReminderDefault.rawValue
    var calendarEnabled = false
    var calendarID: String?
}

struct ReminderDraft: Sendable, Equatable {
    var sourceText: String
    var title: String
    var date: Date?
    var warnings: [Warning]

    enum Warning: String, Sendable {
        case missingDate, missingTime, ambiguous, invalidDate, pastDate, missingTitle, unsupportedRecurrence
    }
    func isCurrent(for text: String) -> Bool { sourceText == text.trimmingCharacters(in: .whitespacesAndNewlines) }
    func canCreate(now: Date, alarmEnabled: Bool) -> Bool {
        do { _ = try validated(now: now, alarmEnabled: alarmEnabled); return true }
        catch { return false }
    }
    enum ValidationError: Error { case title, date }
    func validated(now: Date, alarmEnabled: Bool = true) throws -> (title: String, date: Date?) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ValidationError.title }
        if alarmEnabled {
            guard let date, date.timeIntervalSince1970.isFinite, date > now else { throw ValidationError.date }
        } else if let date, !date.timeIntervalSince1970.isFinite { throw ValidationError.date }
        return (title, date)
    }
}

protocol ReminderInterpreter: Sendable {
    func interpret(text: String, context: InterpretationContext) async throws -> ReminderDraft
}

/// Deliberately bounded Russian grammar. No persistence, permissions or system scheduling.
struct RuleBasedInterpreter: ReminderInterpreter {
    private let numbers = ["ноль": 0, "один": 1, "одну": 1, "одного": 1, "два": 2, "две": 2,
        "три": 3, "четыре": 4, "пять": 5, "шесть": 6, "семь": 7, "восемь": 8, "девять": 9,
        "десять": 10, "одиннадцать": 11, "двенадцать": 12, "тринадцать": 13, "четырнадцать": 14,
        "пятнадцать": 15, "шестнадцать": 16, "семнадцать": 17, "восемнадцать": 18, "девятнадцать": 19,
        "двадцать": 20, "тридцать": 30, "сорок": 40, "пятьдесят": 50]
    private let months = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"]
    private let weekdays = ["воскресенье", "понедельник", "вторник", "среду", "четверг", "пятницу", "субботу"]

    private var numberPattern: String {
        #"(?:\d{1,4}|(?:двадцать|тридцать|сорок|пятьдесят)(?:\s+(?:один|два|две|три|четыре|пять|шесть|семь|восемь|девять))?|"#
            + numbers.keys.filter { ($0 != "двадцать" && $0 != "тридцать" && $0 != "сорок" && $0 != "пятьдесят") }
                .sorted { $0.count > $1.count }.joined(separator: "|") + ")"
    }

    func interpret(text: String, context: InterpretationContext) async throws -> ReminderDraft {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = replace(#"\s+"#, in: source, with: " ")
        var warnings: [ReminderDraft.Warning] = []
        var calendar = context.calendar
        calendar.timeZone = context.timeZone
        let recurrence = #"\b(?:кажд\p{L}*|ежедневно|еженедельно|по\s+(?:понедельникам|вторникам|средам|четвергам|пятницам|субботам|воскресеньям))\b"#
        if !matches(recurrence, phrase).isEmpty {
            return ReminderDraft(sourceText: source, title: cleanTitle(phrase, locale: context.locale), date: nil, warnings: [.unsupportedRecurrence])
        }
        let relativePattern = #"\bчерез\s+(?:("# + numberPattern + #")\s+(минут(?:у|ы)?|час(?:а|ов)?)|(час))\b"#
        let dayPattern = #"\b(послезавтра|завтра|сегодня)\b"#
        let weekdayPattern = #"\b(?:в|на)\s+("# + weekdays.joined(separator: "|") + #")\b"#
        let absolutePattern = #"\b(\d{1,2})\s+("# + months.joined(separator: "|") + #")(?:\s+(\d{4})(?:\s+года)?)?\b"#
        let timePattern = #"(?<![:\d])\b(?:(?:часов\s+)?(?:в|на)\s+("# + numberPattern + #")(?::(\d{2}))?|(\d{1,2}):(\d{2}))(?:\s+(утра|утром|вечера|вечером|дня|днем|днём|ночи|ночью))?\b(?!:)"#
        let relatives = matches(relativePattern, phrase)
        let days = matches(dayPattern, phrase)
        let weekdaysFound = matches(weekdayPattern, phrase)
        let absolutes = matches(absolutePattern, phrase)
        let times = matches(timePattern, phrase)
        let dateCount = relatives.count + days.count + weekdaysFound.count + absolutes.count
        var date: Date?
        if dateCount > 1 || times.count > 1 || (!relatives.isEmpty && !times.isEmpty) {
            warnings.append(.ambiguous)
        } else if let relative = relatives.first {
            let amount = capture(relative, 3, phrase) != nil ? 1 : number(capture(relative, 1, phrase) ?? "")
            let unit = capture(relative, 2, phrase) ?? "час"
            if let amount, amount > 0, amount <= 10000 {
                date = context.now.addingTimeInterval(Double(amount) * (unit.lowercased().hasPrefix("час") ? 3600 : 60))
            } else { warnings.append(.invalidDate) }
        } else {
            if dateCount == 0 { warnings.append(.missingDate) }
            if times.isEmpty { warnings.append(.missingTime) }
            if let time = times.first, dateCount == 1 {
                let hourText = capture(time, 1, phrase) ?? capture(time, 3, phrase) ?? ""
                var hour = number(hourText)
                let minute = Int(capture(time, 2, phrase) ?? capture(time, 4, phrase) ?? "0") ?? -1
                let part = capture(time, 5, phrase)?.lowercased().replacingOccurrences(of: "ё", with: "е")
                if let h = hour, let part {
                    if h > 12 { hour = nil }
                    else if part.hasPrefix("вечер") { hour = h == 12 ? 0 : h + 12 }
                    else if part.hasPrefix("дн") { hour = h == 12 ? 12 : h + 12 }
                    else if part.hasPrefix("утр") { hour = h == 12 ? 0 : h }
                    else if h == 12 { hour = 0 }
                    else if h >= 6 { hour = nil; warnings.append(.ambiguous) }
                } else if Int(hourText) == nil, (hour ?? 24) < 13 {
                    hour = nil; warnings.append(.ambiguous)
                }
                if let hour, (0...23).contains(hour), (0...59).contains(minute) {
                    var day = calendar.startOfDay(for: context.now)
                    var rollWeek = false
                    var rollYear = false
                    if let match = days.first {
                        let name = capture(match, 1, phrase)?.lowercased()
                        let offset = name == "послезавтра" ? 2 : (name == "завтра" ? 1 : 0)
                        day = calendar.date(byAdding: .day, value: offset, to: day) ?? day
                    } else if let match = weekdaysFound.first,
                              let name = capture(match, 1, phrase)?.lowercased(), let index = weekdays.firstIndex(of: name) {
                        let offset = (index + 1 - calendar.component(.weekday, from: day) + 7) % 7
                        day = calendar.date(byAdding: .day, value: offset, to: day) ?? day
                        rollWeek = offset == 0
                    } else if let match = absolutes.first {
                        let d = Int(capture(match, 1, phrase) ?? "") ?? 0
                        let month = months.firstIndex(of: capture(match, 2, phrase)?.lowercased() ?? "").map { $0 + 1 } ?? 0
                        let year = Int(capture(match, 3, phrase) ?? "") ?? calendar.component(.year, from: day)
                        rollYear = capture(match, 3, phrase) == nil
                        if let proposed = calendar.date(from: DateComponents(year: year, month: month, day: d)),
                           calendar.component(.month, from: proposed) == month, calendar.component(.day, from: proposed) == d {
                            day = proposed
                        } else { warnings.append(.invalidDate) }
                    }
                    if !warnings.contains(.invalidDate) {
                        date = wallTime(on: day, hour: hour, minute: minute, calendar: calendar)
                        if date == nil { warnings.append(.invalidDate) }
                        if let candidate = date, candidate <= context.now, rollWeek || rollYear {
                            day = calendar.date(byAdding: rollWeek ? .day : .year, value: rollWeek ? 7 : 1, to: day) ?? day
                            date = wallTime(on: day, hour: hour, minute: minute, calendar: calendar)
                        }
                    }
                } else if !warnings.contains(.ambiguous) { warnings.append(.invalidDate) }
            }
        }
        var title = phrase
        for pattern in [relativePattern, absolutePattern, weekdayPattern, dayPattern, timePattern] {
            title = replace(pattern, in: title, with: " ")
        }
        // Unsupported leftover temporal clauses must not silently become a different schedule.
        if !matches(#"\b(?:через|или)\b|\b\d+\s+(?:минут|час|дней|недель)"#, title).isEmpty {
            date = nil; warnings.append(.ambiguous)
        }
        title = cleanTitle(title, locale: context.locale)
        if title.isEmpty { title = source; warnings.append(.missingTitle) }
        if let date, date <= context.now { warnings.append(.pastDate) }
        return ReminderDraft(sourceText: source, title: title, date: date, warnings: Array(Set(warnings)).sorted { $0.rawValue < $1.rawValue })
    }

    private func wallTime(on day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        let first = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day, matchingPolicy: .strict, repeatedTimePolicy: .first)
        let last = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day, matchingPolicy: .strict, repeatedTimePolicy: .last)
        guard let first, first == last, calendar.isDate(first, inSameDayAs: day),
              calendar.component(.hour, from: first) == hour, calendar.component(.minute, from: first) == minute else { return nil }
        return first
    }
    private func number(_ text: String) -> Int? {
        let text = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        if let n = Int(text) { return n }
        let parts = text.split(separator: " ").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ numbers[$0] != nil }) else { return nil }
        return parts.reduce(0) { $0 + (numbers[$1] ?? 0) }
    }
    private func cleanTitle(_ text: String, locale: Locale) -> String {
        var value = replace(#"\s+"#, in: text, with: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let intro = #"^(?:слушай|пожалуйста|напомни(?:\s+мне)?|поставь\s+напоминание(?:\s+на)?|нужно|надо|не\s+забудь)\b[,\s:]*"#
        while true {
            let updated = replace(intro, in: value, with: "").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if updated == value { break }; value = updated
        }
        guard let first = value.first else { return "" }
        return String(first).uppercased(with: locale) + value.dropFirst()
    }
    private func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private func capture(_ match: NSTextCheckingResult, _ group: Int, _ text: String) -> String? {
        guard let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
    private func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
}
