import EventKit
import Foundation

struct CalendarDestination: Identifiable, Equatable {
    let id: String
    let name: String
}

struct CalendarIdentity {
    let eventID: String
    let externalID: String?
    let calendarID: String
}

struct CalendarRequest {
    let id: UUID
    let title: String
    let date: Date
    let calendarID: String?
    let eventID: String?
    let externalID: String?
    let previousDate: Date?
    let allowCreate: Bool

    var endDate: Date { date.addingTimeInterval(900) }
    var url: URL { ReminderLink.url(for: id) }
    var notes: String { String(localized: "Managed by Nudge. Edit this task in Nudge.") + "\n" + Self.marker(for: id) }
    static func marker(for id: UUID) -> String { "nudge-reminder-id:\(id.uuidString)" }
    static func owns(url: URL?, notes: String?, id: UUID) -> Bool {
        guard let url, ReminderLink.id(from: url) == id else { return false }
        return notes?.components(separatedBy: .newlines).contains(marker(for: id)) == true
    }
}

/// Small synchronous EventKit boundary; only permission acquisition suspends.
@MainActor
struct CalendarService {
    static let defaultKey = "calendarDefaultEnabled"
    static let destinationKey = "calendarDestinationID"
    var hasAccess: () -> Bool
    var authorize: () async throws -> Void = { throw CalendarError.permission }
    var destinations: () -> [CalendarDestination] = { [] }
    var createCalendar: () throws -> String = { throw CalendarError.destination }
    var upsert: (CalendarRequest) throws -> CalendarIdentity
    var remove: (CalendarRequest) throws -> Void

    static var live: CalendarService {
        let client = CalendarClient.shared
        return CalendarService(hasAccess: { client.hasAccess }, authorize: { try await client.authorize() },
            destinations: { client.destinations() }, createCalendar: { try client.createCalendar() },
            upsert: { try client.upsert($0) }, remove: { try client.remove($0) })
    }
}

enum CalendarError: LocalizedError, Equatable {
    case permission, destination, missing, ambiguous
    var errorDescription: String? {
        switch self {
        case .permission: String(localized: "Calendar access is unavailable. Connect Calendar in Settings or allow full access in iOS Settings.")
        case .destination: String(localized: "Choose a writable calendar in Settings. A separate Nudge calendar may not be supported by this account.")
        case .missing: String(localized: "The linked event could not be found safely. It may have been deleted or moved. No new copy was created. Check Calendar and retry.")
        case .ambiguous: String(localized: "Several events match this task or its link was changed. Nothing was modified. Check Calendar before retrying.")
        }
    }
}

@MainActor
private final class CalendarClient {
    static let shared = CalendarClient()
    private let store = EKEventStore()
    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func authorize() async throws {
        guard try await store.requestFullAccessToEvents() else { throw CalendarError.permission }
    }

    func destinations() -> [CalendarDestination] {
        guard hasAccess else { return [] }
        return store.calendars(for: .event).filter(\.allowsContentModifications).map {
            CalendarDestination(id: $0.calendarIdentifier, name: "\($0.title) · \($0.source.title)")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func createCalendar() throws -> String {
        guard hasAccess else { throw CalendarError.permission }
        let existing = store.calendars(for: .event).filter { $0.title == "Nudge" && $0.allowsContentModifications }
        guard existing.count < 2 else { throw CalendarError.destination }
        if let calendar = existing.first { return calendar.calendarIdentifier }
        let source = store.defaultCalendarForNewEvents?.source
            ?? store.sources.first { $0.sourceType == .local || $0.sourceType == .calDAV }
        guard let source else { throw CalendarError.destination }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Nudge"
        calendar.source = source
        do { try store.saveCalendar(calendar, commit: true) }
        catch { store.reset(); throw error }
        return calendar.calendarIdentifier
    }

    private func find(_ request: CalendarRequest) throws -> EKEvent? {
        guard hasAccess else { throw CalendarError.permission }
        var matches: [String: EKEvent] = [:]
        func consider(_ event: EKEvent) throws {
            guard CalendarRequest.owns(url: event.url, notes: event.notes, id: request.id) else { return }
            guard !(event.hasRecurrenceRules) else { throw CalendarError.ambiguous }
            matches[event.eventIdentifier ?? event.calendarItemIdentifier] = event
        }
        if let id = request.eventID, let event = store.event(withIdentifier: id) {
            // An identifier alone never grants ownership of an event.
            guard CalendarRequest.owns(url: event.url, notes: event.notes, id: request.id) else { throw CalendarError.ambiguous }
            try consider(event)
        }
        if let external = request.externalID {
            for case let event as EKEvent in store.calendarItems(withExternalIdentifier: external) { try consider(event) }
        }
        for date in Set([request.date, request.previousDate].compactMap { $0 }) {
            let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-86400),
                end: date.addingTimeInterval(86400), calendars: nil)
            for event in store.events(matching: predicate) { try consider(event) }
        }
        guard matches.count < 2 else { throw CalendarError.ambiguous }
        return matches.values.first
    }

    func upsert(_ request: CalendarRequest) throws -> CalendarIdentity {
        let existing = try find(request)
        guard existing != nil || request.allowCreate else { throw CalendarError.missing }
        let event: EKEvent
        if let existing {
            event = existing // Follow a verified event if the user moved it to another calendar.
        } else {
            guard let id = request.calendarID, let calendar = store.calendar(withIdentifier: id), calendar.allowsContentModifications else {
                throw CalendarError.destination
            }
            event = EKEvent(eventStore: store)
            event.calendar = calendar
        }
        guard event.calendar?.allowsContentModifications == true else { throw CalendarError.destination }
        let changed = existing == nil || event.title != request.title || event.startDate != request.date
            || event.endDate != request.endDate || event.url != request.url || event.notes != request.notes
            || event.hasAlarms || event.isAllDay
        if changed {
            event.title = request.title
            event.startDate = request.date
            event.endDate = request.endDate
            event.isAllDay = false
            event.url = request.url
            event.notes = request.notes
            event.alarms = [] // Calendar must not create a second alert alongside AlarmKit.
            do { try store.save(event, span: .thisEvent, commit: true) }
            catch { store.reset(); throw error }
        }
        guard let id = event.eventIdentifier else { throw CalendarError.missing }
        return CalendarIdentity(eventID: id, externalID: event.calendarItemExternalIdentifier, calendarID: event.calendar.calendarIdentifier)
    }

    func remove(_ request: CalendarRequest) throws {
        guard let event = try find(request) else {
            if request.eventID == nil && request.previousDate != nil { throw CalendarError.missing }
            return // A previously identified, already-removed event needs no mutation.
        }
        guard event.calendar?.allowsContentModifications == true else { throw CalendarError.destination }
        do { try store.remove(event, span: .thisEvent, commit: true) }
        catch { store.reset(); throw error }
    }
}
