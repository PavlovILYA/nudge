import Foundation

enum ReminderLink {
    static func url(for id: UUID) -> URL { URL(string: "nudge://reminder/\(id.uuidString)")! }
    static func id(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == "nudge", url.host?.lowercased() == "reminder",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 1 else { return nil }
        return UUID(uuidString: String(parts[0]))
    }
}
