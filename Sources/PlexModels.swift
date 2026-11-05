import Foundation

enum PlexError: Error, LocalizedError {
    case unsafeURL, authentication, unavailable, malformed, incomplete, storage, unsupported
    var errorDescription: String? {
        switch self {
        case .unsafeURL: return "This connection or media address is not permitted. Use a discovered HTTPS connection. Redirects are blocked."
        case .authentication: return "Plex authorization expired or access was revoked. Link again, then retry. Offline books remain available."
        case .unavailable: return "Plex could not be reached or declined the request. Check your connection and server access, then retry."
        case .malformed: return "Plex returned an unsupported or incomplete library response."
        case .incomplete: return "The download was incomplete or was not an audio file. Retry to continue."
        case .storage: return "Not enough available storage for this book. Delete a local download and retry."
        case .unsupported: return "This book has no compatible original audio. Transcoding is not enabled."
        }
    }
}

enum PlexURL {
    static func origin(_ url: URL) -> String? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.fragment == nil else { return nil }
        return "https://\(host.lowercased()):\(c.port ?? 443)"
    }
    static func base(_ text: String) throws -> URL {
        guard let url = URL(string: text), origin(url) != nil,
              url.query == nil, ["", "/"].contains(url.path) else { throw PlexError.unsafeURL }
        return url
    }
    static func resolve(_ key: String, base: URL) throws -> URL {
        // Server-supplied keys must be root-relative paths, never absolute URLs.
        guard key.hasPrefix("/"), !key.hasPrefix("//"), !key.contains("\\"),
              let c = URLComponents(string: key), c.scheme == nil, c.host == nil,
              c.query == nil, c.fragment == nil,
              let url = URL(string: key, relativeTo: base)?.absoluteURL,
              origin(url) == origin(base), origin(url) != nil else { throw PlexError.unsafeURL }
        return url
    }
    static func component(_ value: String) throws -> String {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { throw PlexError.malformed }
        return value
    }
}

struct PlexEnvelope: Decodable { let MediaContainer: PlexContainer }
struct PlexContainer: Decodable {
    var machineIdentifier: String?
    var offset: Int?
    var size: Int?
    var totalSize: Int?
    var Metadata: [PlexMetadata]?
    var Directory: [PlexDirectory]?
}
struct PlexDirectory: Decodable, Identifiable {
    let key: String
    let title: String
    let type: String?
    var id: String { key }
}
struct PlexMetadata: Decodable, Identifiable {
    let ratingKey: String
    let title: String
    var type: String?
    var parentTitle: String?
    var grandparentTitle: String?
    var thumb: String?
    var parentThumb: String?
    var index: Int?
    var parentIndex: Int?
    var duration: Double?
    var Media: [PlexMedia]?
    var Chapter: [PlexChapter]?
    var id: String { ratingKey }
}
struct PlexMedia: Decodable {
    var container: String?
    var audioCodec: String?
    var Part: [PlexPart]?
}
struct PlexPart: Decodable {
    let key: String
    var size: Int64?
    var duration: Double?
    var container: String?
}
struct PlexChapter: Codable {
    var tag: String?
    var startTimeOffset: Double
    var endTimeOffset: Double?
}
struct PlexResource: Decodable, Identifiable {
    let name: String
    let clientIdentifier: String
    let provides: String
    let accessToken: String?
    let connections: [PlexConnection]
    var id: String { clientIdentifier }
}
struct PlexConnection: Decodable, Identifiable {
    let uri: String
    let isLocal: Bool
    enum CodingKeys: String, CodingKey { case uri, isLocal = "local", relay }
    let relay: Bool?
    var id: String { uri }
}
struct BookTrack: Codable, Identifiable {
    var id: String
    var title: String
    var key: String
    var duration: Double
    var bytes: Int64
    var ext: String
    var filename: String?
    var chapters: [PlexChapter]?
}
struct PlexBookSource: Codable {
    var serverID: String
    var ratingKey: String
    var author: String?
    var artwork: String?
    var tracks: [BookTrack]
    var identity: String { serverID + ":" + ratingKey }
}

enum PlexBooks {
    static func tracks(_ metadata: [PlexMetadata]) throws -> [BookTrack] {
        let sorted = metadata.sorted {
            let left = [$0.parentIndex ?? 1, $0.index ?? 0]
            let right = [$1.parentIndex ?? 1, $1.index ?? 0]
            if left != right { return left.lexicographicallyPrecedes(right) }
            return $0.ratingKey.localizedStandardCompare($1.ratingKey) == .orderedAscending
        }
        var result: [BookTrack] = []
        for track in sorted {
            guard let media = track.Media?.first(where: { media in
                ["mp3", "m4a", "m4b", "mp4", "aac", "wav"].contains(media.container?.lowercased() ?? "")
            }), let parts = media.Part, !parts.isEmpty else { throw PlexError.unsupported }
            for (index, part) in parts.enumerated() {
                let ext = (part.container ?? media.container ?? "").lowercased()
                guard ["mp3", "m4a", "m4b", "mp4", "aac", "wav"].contains(ext),
                      let bytes = part.size, bytes > 0 else { throw PlexError.malformed }
                let duration = (part.duration ?? (parts.count == 1 ? track.duration : nil) ?? 0) / 1000
                guard duration > 0 else { throw PlexError.malformed }
                result.append(BookTrack(id: "\(track.ratingKey):\(index)", title: track.title,
                    key: part.key, duration: duration, bytes: bytes, ext: ext,
                    chapters: parts.count == 1 ? track.Chapter : nil))
            }
        }
        guard !result.isEmpty else { throw PlexError.unsupported }
        return result
    }
}

enum DownloadValidation {
    static func check(status: Int, mime: String?, actual: Int64, expected: Int64) throws {
        guard status == 200 || status == 206, expected > 0, actual == expected,
              let mime, mime.hasPrefix("audio/") || ["application/octet-stream", "video/mp4", "application/mp4"].contains(mime) else { throw PlexError.incomplete }
    }
}
