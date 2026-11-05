import Foundation
import Combine

// All network sessions fail closed on redirects, including same-host redirects.
// No authentication challenge handler: system TLS validation remains in force.
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class PlexTransport {
    static let shared = PlexTransport()
    private let delegate = NoRedirect()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
    static func request(url: URL, token: String = "", client: String = "") throws -> URLRequest {
        guard PlexURL.origin(url) != nil,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                  ["x-plex-token", "devicejwt", "token", "auth_token"].contains($0.name.lowercased())
              }) != true else { throw PlexError.unsafeURL }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BookHarbor", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")
        if !client.isEmpty { request.setValue(client, forHTTPHeaderField: "X-Plex-Client-Identifier") }
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        return request
    }
    func data(_ request: URLRequest, limit: Int = 16 * 1024 * 1024) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw PlexError.unavailable }
            if [401, 403, 498].contains(http.statusCode) { throw PlexError.authentication }
            guard (200...299).contains(http.statusCode) else { throw PlexError.unavailable }
            // Reject ignored Range requests/oversized responses before buffering them.
            guard response.expectedContentLength <= Int64(limit) else { throw PlexError.incomplete }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw PlexError.incomplete }
                data.append(byte)
            }
            return (data, http)
        } catch is CancellationError { throw CancellationError() }
        catch let error as PlexError { throw error }
        catch { throw PlexError.unavailable } // Never expose underlying URL/userInfo.
    }
}

@MainActor final class PlexClient: ObservableObject {
    @Published var status = ""
    @Published var busy = false
    @Published var linked = !SecureSettings.read("plex-account").isEmpty
    @Published var servers: [PlexResource] = []
    @Published var libraries: [PlexDirectory] = []
    @Published var albums: [PlexMetadata] = []
    @Published var selectedServer: String?
    @Published var selectedLibrary: String?
    @Published var hasMore = false
    @Published var browserURL: URL?
    private var linking: Task<Void, Never>?
    private var offset = 0
    private var generation = UUID()
    private var pin: Pin?
    struct Pin: Decodable { let id: Int; let code: String; let authToken: String?; let expiresIn: Int? }
    var clientID: String {
        get throws {
            let stored = SecureSettings.read("plex-client")
            if !stored.isEmpty { return stored }
            let new = UUID().uuidString
            try SecureSettings.write(new, key: "plex-client")
            return new
        }
    }
    func beginLink() async {
        cancelLink()
        busy = true; status = "Creating a private Plex browser link…"
        defer { busy = false }
        do {
            var request = try PlexTransport.request(url: URL(string: "https://plex.tv/api/v2/pins?strong=true")!, client: clientID)
            request.httpMethod = "POST"
            let (data, _) = try await PlexTransport.shared.data(request)
            let pin = try JSONDecoder().decode(Pin.self, from: data)
            self.pin = pin
            var query = URLComponents()
            query.queryItems = [URLQueryItem(name: "clientID", value: try clientID),
                                URLQueryItem(name: "code", value: pin.code),
                                URLQueryItem(name: "context[device][product]", value: "BookHarbor")]
            browserURL = URL(string: "https://app.plex.tv/auth#?" + (query.percentEncodedQuery ?? ""))
            status = "Finish signing in with Plex in the browser, then return here."
            linking = Task { [weak self] in
                for _ in 0..<min(pin.expiresIn ?? 300, 900) / 2 {
                    do { try await Task.sleep(nanoseconds: 2_000_000_000); try Task.checkCancellation() }
                    catch { return }
                    guard let self else { return }
                    do {
                        let request = try PlexTransport.request(url: URL(string: "https://plex.tv/api/v2/pins/\(pin.id)")!, client: self.clientID)
                        let (data, _) = try await PlexTransport.shared.data(request)
                        let result = try JSONDecoder().decode(Pin.self, from: data)
                        try Task.checkCancellation()
                        if let token = result.authToken, !token.isEmpty {
                            try SecureSettings.write(token, key: "plex-account")
                            self.linked = true; self.browserURL = nil; self.pin = nil
                            self.status = "Linked. Discovering servers…"
                            await self.discover(); return
                        }
                    } catch is CancellationError { return }
                    catch { self.status = "Linking could not be completed. Start a new link."; return }
                }
                self?.status = "The sign-in link expired. Start a new link."
                self?.browserURL = nil
            }
        } catch { status = "Could not create the Plex link. Check your connection and retry." }
    }
    func cancelLink() { linking?.cancel(); linking = nil; pin = nil; browserURL = nil }
    func discover() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let request = try PlexTransport.request(url: URL(string: "https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=1")!, token: SecureSettings.read("plex-account"), client: clientID)
            let (data, _) = try await PlexTransport.shared.data(request)
            servers = try JSONDecoder().decode([PlexResource].self, from: data).filter { $0.provides.split(separator: ",").contains("server") }
            status = servers.isEmpty ? "No authorized Plex servers were found." : "Choose a server. Only validated HTTPS connections are used."
        } catch { report(error) }
    }
    func select(_ server: PlexResource) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        generation = UUID(); selectedServer = nil; selectedLibrary = nil
        libraries = []; albums = []; hasMore = false
        let connections = server.connections.sorted { ($0.relay == true ? 2 : $0.isLocal ? 0 : 1) < ($1.relay == true ? 2 : $1.isLocal ? 0 : 1) }
        for connection in connections {
            do {
                let base = try PlexURL.base(connection.uri)
                guard let token = server.accessToken, !token.isEmpty else { throw PlexError.authentication }
                let request = try PlexTransport.request(url: PlexURL.resolve("/", base: base), token: token, client: clientID)
                let (data, _) = try await PlexTransport.shared.data(request)
                let identity = try JSONDecoder().decode(PlexEnvelope.self, from: data).MediaContainer.machineIdentifier
                guard identity == server.clientIdentifier else { throw PlexError.unsafeURL }
                // A connection must originate in authenticated account discovery AND
                // pass HTTPS/system certificate validation AND match server identity.
                try SecureSettings.write(base.absoluteString, key: "plex-base-" + server.id)
                try SecureSettings.write(token, key: "plex-token-" + server.id)
                selectedServer = server.id
                let container = try await container("/library/sections", server: server.id)
                libraries = (container.Directory ?? []).filter { $0.type == "artist" }
                status = libraries.isEmpty ? "No music libraries found. Audiobooks must be organized as albums with audio tracks." : "Choose your audiobook music library."
                return
            } catch { continue }
        }
        status = "No authorized HTTPS connection succeeded. Check server availability and secure connections, or link again if access was revoked. HTTP-only connections are unsupported."
    }
    func selectLibrary(_ library: PlexDirectory) async {
        guard !busy else { return }
        generation = UUID(); selectedLibrary = library.key; offset = 0; albums = []; hasMore = true
        await loadMore()
    }
    func loadMore() async {
        guard !busy, hasMore, let server = selectedServer, let library = selectedLibrary else { return }
        busy = true; defer { busy = false }
        let current = generation
        do {
            let key = try PlexURL.component(library)
            let page = try await container("/library/sections/\(key)/all", server: server, query: [URLQueryItem(name: "type", value: "9")], start: offset)
            guard current == generation else { return }
            let entries = page.Metadata ?? []
            guard page.offset == nil || page.offset == offset else { throw PlexError.malformed }
            let fresh = entries.filter { item in !albums.contains(where: { $0.id == item.id }) }
            albums += fresh; offset += entries.count
            hasMore = !fresh.isEmpty && offset < (page.totalSize ?? (entries.count >= 50 ? Int.max : offset))
            status = "\(albums.count) books loaded. Books are Plex albums; disc and track numbers determine playback order."
        } catch { report(error) }
    }
    func book(_ album: PlexMetadata, library: Library) async throws -> Book {
        guard let server = selectedServer else { throw PlexError.unavailable }
        let key = try PlexURL.component(album.ratingKey)
        var all: [PlexMetadata] = []
        var start = 0
        while true {
            let page = try await container("/library/metadata/\(key)/children", server: server, query: [URLQueryItem(name: "includeChapters", value: "1")], start: start)
            let entries = page.Metadata ?? []
            guard page.offset == nil || page.offset == start else { throw PlexError.malformed }
            guard !entries.contains(where: { entry in all.contains(where: { $0.id == entry.id }) }) else { throw PlexError.malformed }
            all += entries; start += entries.count
            if entries.isEmpty || start >= (page.totalSize ?? (entries.count < 50 ? start : Int.max)) { break }
            guard start < 100_000 else { throw PlexError.malformed }
        }
        let tracks = try PlexBooks.tracks(all)
        let source = PlexBookSource(serverID: server, ratingKey: album.ratingKey, author: album.parentTitle,
                                   artwork: album.thumb, tracks: tracks)
        // Validate every media path before storing metadata or scheduling work.
        for track in tracks { _ = try mediaRequest(source: source, track: track) }
        return try library.upsert(title: album.title, source: source)
    }
    func mediaRequest(source: PlexBookSource, track: BookTrack) throws -> URLRequest {
        try request(track.key, server: source.serverID)
    }
    func request(_ key: String, server: String) throws -> URLRequest {
        let base = try PlexURL.base(SecureSettings.read("plex-base-" + server))
        let token = SecureSettings.read("plex-token-" + server)
        guard !token.isEmpty, linked else { throw PlexError.authentication }
        return try PlexTransport.request(url: PlexURL.resolve(key, base: base), token: token, client: clientID)
    }
    func container(_ key: String, server: String, query: [URLQueryItem] = [], start: Int = 0) async throws -> PlexContainer {
        var request = try request(key, server: server)
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.queryItems = query.isEmpty ? nil : query
        request.url = url.url
        request.setValue(String(start), forHTTPHeaderField: "X-Plex-Container-Start")
        request.setValue("50", forHTTPHeaderField: "X-Plex-Container-Size")
        let (data, _) = try await PlexTransport.shared.data(request)
        return try JSONDecoder().decode(PlexEnvelope.self, from: data).MediaContainer
    }
    func signOut() throws {
        cancelLink(); generation = UUID()
        // Enumerate service accounts so tokens for previously selected servers are removed too.
        try SecureSettings.clearPlex()
        linked = false; selectedServer = nil; selectedLibrary = nil
        servers = []; libraries = []; albums = []; hasMore = false
        status = "Signed out on this iPhone. Completed downloads and local progress remain. You can revoke BookHarbor in Plex Authorized Devices."
    }
    func report(_ error: Error) { status = (error as? PlexError)?.errorDescription ?? "Plex could not complete the request. Please retry." }
}
