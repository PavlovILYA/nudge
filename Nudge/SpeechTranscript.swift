import CoreMedia
import Foundation

/// Modern speech results replace an audio interval, not the whole utterance.
/// Word-level parts retain unaffected text when a result's boundaries change.
struct SpeechTranscript: Sendable {
    struct Part: Sendable {
        var text: String
        let range: CMTimeRange
    }

    private var parts: [Part] = []
    private var finalizedThrough = CMTime.zero

    var text: String {
        parts.reduce(into: "") { result, part in
            let fragment = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fragment.isEmpty else { return }
            let closes = fragment.first.map { ",.;:!?)]}»".contains($0) } == true
            let opens = result.last.map { "([{«".contains($0) } == true
            if !result.isEmpty, !closes, !opens { result += " " }
            result += fragment
        }
    }

    mutating func replace(range: CMTimeRange, with replacement: [Part], finalizedThrough watermark: CMTime) {
        // Use exact CMTime comparisons; touching intervals are separate phrases.
        if Self.valid(range), CMTimeCompare(range.start, finalizedThrough) >= 0 {
            parts.removeAll { Self.overlaps($0.range, range) }
            parts.append(contentsOf: replacement.filter { Self.valid($0.range) && Self.overlaps($0.range, range) })
            parts.sort { CMTimeCompare($0.range.start, $1.range.start) < 0 }
        }
        // Earlier volatile results can become final without ever being reissued.
        if watermark.isNumeric, CMTimeCompare(watermark, finalizedThrough) > 0 {
            finalizedThrough = watermark
        }
    }

    private static func valid(_ range: CMTimeRange) -> Bool {
        range.isValid && range.start.isNumeric && range.duration.isNumeric && CMTimeCompare(range.duration, .zero) > 0
    }
    private static func overlaps(_ lhs: CMTimeRange, _ rhs: CMTimeRange) -> Bool {
        CMTimeCompare(lhs.start, rhs.end) < 0 && CMTimeCompare(rhs.start, lhs.end) < 0
    }
}

/// Full user request, independent of the interpreted task title. Each new audio
/// session can revise only its hypothesis; manual edits invalidate that session.
struct VoiceTextBuffer: Sendable {
    private(set) var confirmed = ""
    private(set) var hypothesis = ""
    private var session: UUID?
    var text: String { [confirmed, hypothesis].filter { !$0.isEmpty }.joined(separator: " ") }
    mutating func begin() -> UUID {
        confirmed = text; hypothesis = ""
        let id = UUID(); session = id; return id
    }
    mutating func update(_ text: String, session id: UUID) {
        guard session == id else { return }
        hypothesis = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    mutating func finish(session id: UUID) {
        guard session == id else { return }
        confirmed = text; hypothesis = ""; session = nil
    }
    mutating func edit(_ text: String) {
        confirmed = text; hypothesis = ""; session = nil
    }
}
