import Foundation
import Combine

enum PlaybackState: String { case idle = "Ready", loading = "Loading", buffering = "Buffering", playing = "Playing", paused = "Paused", failed = "Failed" }
enum PlaybackStage: String { case selection, metadata, connection, authentication, source, item, readiness, seek, http, range, buffering, audioSession, playing, paused, failure }
enum PlaybackFact: String { case started, ready, local, streaming, complete, interrupted, timeout, unsupported, response, rejected, cancelled, waiting, failed }

// RAM only. Deliberately no free-form strings, URLs, identifiers, positions, titles,
// headers, NSError descriptions or response bodies can enter this trace.
struct PlaybackDiagnostic: Identifiable {
    let id = UUID()
    let stage: PlaybackStage
    let fact: PlaybackFact
    let code: Int?
    var line: String { stage.rawValue + ": " + fact.rawValue + (code.map { " (code \($0))" } ?? "") }
}
@MainActor final class PlaybackDiagnostics: ObservableObject {
    @Published private(set) var events: [PlaybackDiagnostic] = []
    func clear() { events = [] }
    func record(_ stage: PlaybackStage, _ fact: PlaybackFact, code: Int? = nil) {
        events.append(PlaybackDiagnostic(stage: stage, fact: fact, code: code))
        if events.count > 32 { events.removeFirst(events.count - 32) }
    }
    var text: String { events.map(\.line).joined(separator: "\n") }
    func recordErrorCodes(_ error: Error?, stage: PlaybackStage) {
        var current = error as NSError?
        for _ in 0..<3 {
            guard let value = current else { break }
            record(stage, .failed, code: value.code)
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
    }
}

// Initial restore is a one-shot action gated on readiness, never on a speculative
// seek issued while AVPlayerItem.status is still unknown.
struct PlaybackPreparation {
    var offset: Double
    private(set) var ready = false
    private(set) var restoreIssued = false
    mutating func becameReady() -> Double? {
        ready = true
        guard !restoreIssued else { return nil }
        restoreIssued = true
        return max(0, offset.isFinite ? offset : 0)
    }
    mutating func requestSeek(_ offset: Double) -> Double? {
        self.offset = max(0, offset.isFinite ? offset : 0)
        return ready ? self.offset : nil
    }
}

enum MediaRange {
    static func end(offset: Int64, length: Int, allToEnd: Bool, total: Int64) throws -> Int64 {
        guard offset >= 0, total > 0, length >= 0 else { throw PlexError.range }
        if offset >= total { return total }
        if allToEnd { return total }
        return offset + min(Int64(length), total - offset)
    }
    static func validate(_ response: HTTPURLResponse, count: Int, offset: Int64, last: Int64, total: Int64) throws -> Int64 {
        guard response.statusCode == 206 else { throw PlexError.http(response.statusCode) }
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
              let space = header.firstIndex(of: " "), header[..<space].lowercased() == "bytes" else { throw PlexError.range }
        let pieces = header[header.index(after: space)...].split(separator: "/")
        guard pieces.count == 2, let size = Int64(pieces[1]), size == total else { throw PlexError.range }
        let bounds = pieces[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start == offset, end >= start, end <= last, end < total,
              Int64(count) == end - start + 1 else { throw PlexError.range }
        // A server may satisfy less than the requested range. Continue at end+1.
        return end + 1
    }
}
