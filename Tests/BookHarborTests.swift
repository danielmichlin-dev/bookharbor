import XCTest
import AVFoundation
@testable import BookHarbor

final class BookHarborTests: XCTestCase {
    func testEmbeddedChapterGroupsPreserveTitleAndExactTimes() async {
        let title = AVMutableMetadataItem()
        title.keySpace = .common; title.key = AVMetadataKey.commonKeyTitle as NSString
        title.value = "Synthetic embedded chapter" as NSString
        let group = AVTimedMetadataGroup(items: [title], timeRange: CMTimeRange(start: CMTime(seconds: 2.125, preferredTimescale: 600), duration: CMTime(seconds: 4.5, preferredTimescale: 600)))
        let chapters = await ChapterReader.parse([group], track: 1)
        XCTAssertEqual(chapters.first?.title, "Synthetic embedded chapter")
        XCTAssertEqual(chapters.first?.start, 2.125)
        XCTAssertEqual(chapters.first?.end, 6.625)
        XCTAssertEqual(chapters.first?.trackIndex, 1)
    }
    @MainActor func testUnreadableIndexIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("index.json")
        let original = Data("synthetic-invalid-index".utf8)
        try original.write(to: index)
        let library = Library(root: root)
        XCTAssertFalse(library.save())
        XCTAssertThrowsError(try library.upsert(title: "Synthetic", source: sampleSource("server", key: "1")))
        XCTAssertEqual(try Data(contentsOf: index), original)
    }
    func testSafeURLsAndHeaderAuthentication() throws {
        let base = try PlexURL.base("https://media.example.invalid:32400")
        let url = try PlexURL.resolve("/library/parts/7/audio.m4b", base: base)
        let request = try PlexTransport.request(url: url, token: "synthetic-test-value", client: "synthetic-client")
        XCTAssertNil(url.query)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Plex-Token"))
        for key in ["https://other.example.invalid/audio", "//other.example.invalid/audio", "/a?token=synthetic", "/a#fragment", "/\\other/audio"] {
            XCTAssertThrowsError(try PlexURL.resolve(key, base: base))
        }
        var credentialURL = URLComponents(string: "https://media.example.invalid")!
        credentialURL.user = "synthetic-user"; credentialURL.password = "synthetic-password"
        XCTAssertThrowsError(try PlexURL.base(credentialURL.string!))
        for base in ["http://media.example.invalid", "https://media.example.invalid?token=synthetic", "https://media.example.invalid/path"] {
            XCTAssertThrowsError(try PlexURL.base(base))
        }
    }
    func testRedirectIsRefused() {
        let delegate = NoRedirect()
        let url = URL(string: "https://media.example.invalid")!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var called = false
        delegate.urlSession(.shared, task: URLSession.shared.dataTask(with: url), willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "https://other.example.invalid")!)) { request in
            called = true; XCTAssertNil(request)
        }
        XCTAssertTrue(called)
    }
    func testPlexParsingAndMultipartOrdering() throws {
        let data = Data(#"{"MediaContainer":{"offset":0,"totalSize":3,"Metadata":[{"ratingKey":"30","title":"Second disc","parentIndex":2,"index":1,"duration":30000,"Media":[{"container":"mp3","Part":[{"key":"/library/parts/30/audio.mp3","size":300}]}]},{"ratingKey":"20","title":"Second track","parentIndex":1,"index":2,"duration":20000,"Media":[{"container":"m4b","Part":[{"key":"/library/parts/20/audio.m4b","size":200}]}]},{"ratingKey":"10","title":"First track","parentIndex":1,"index":1,"duration":10000,"Media":[{"container":"mp3","Part":[{"key":"/library/parts/10/audio.mp3","size":100}]}],"Chapter":[{"tag":"Opening","startTimeOffset":0,"endTimeOffset":5000},{"tag":"Following","startTimeOffset":5000,"endTimeOffset":10000}]}]}}"#.utf8)
        let page = try JSONDecoder().decode(PlexEnvelope.self, from: data).MediaContainer
        let tracks = try PlexBooks.tracks(page.Metadata!)
        XCTAssertEqual(tracks.map(\.id), ["10:0", "20:0", "30:0"])
        XCTAssertEqual(tracks.map(\.duration), [10, 20, 30])
        XCTAssertEqual(page.totalSize, 3)
        let chapters = BookTimeline.chapters(tracks[0].chapters!, track: 0, duration: 10)
        XCTAssertEqual(chapters.map(\.title), ["Opening", "Following"])
        XCTAssertEqual(chapters.map(\.duration), [5, 5])
        let location = BookTimeline.location(35.25, tracks: tracks)
        XCTAssertEqual(location.0, 2); XCTAssertEqual(location.1, 5.25)
        XCTAssertEqual(BookTimeline.absolute(track: 2, offset: 5.25, tracks: tracks), 35.25)
        XCTAssertEqual(BookTimeline.location(10, tracks: tracks).0, 1)
    }
    func testMalformedChaptersAndNavigation() {
        let chapters = BookTimeline.chapters([
            PlexChapter(tag: "Middle", startTimeOffset: 4000, endTimeOffset: nil),
            PlexChapter(tag: "Opening", startTimeOffset: 0, endTimeOffset: 4000),
            PlexChapter(tag: "Invalid", startTimeOffset: -1000, endTimeOffset: -500),
            PlexChapter(tag: "Outside", startTimeOffset: 15000, endTimeOffset: 17000)
        ], track: 1, duration: 10)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[1].end, 10)
        let tracks = [sampleTrack("one", duration: 20), sampleTrack("two", duration: 10)]
        XCTAssertEqual(BookTimeline.absolute(track: chapters[1].trackIndex, offset: chapters[1].start, tracks: tracks), 24)
        let location = BookTimeline.location(24, tracks: tracks)
        XCTAssertEqual(location.0, 1); XCTAssertEqual(location.1, 4)
    }
    func testDownloadCompletionAndFailures() throws {
        try DownloadValidation.check(status: 200, mime: "audio/mp4", actual: 100, expected: 100)
        try DownloadValidation.check(status: 206, mime: "application/octet-stream", actual: 100, expected: 100)
        for status in [302, 401, 403, 404, 500] {
            XCTAssertThrowsError(try DownloadValidation.check(status: status, mime: "audio/mp4", actual: 100, expected: 100))
        }
        XCTAssertThrowsError(try DownloadValidation.check(status: 200, mime: "text/html", actual: 100, expected: 100))
        XCTAssertThrowsError(try DownloadValidation.check(status: 200, mime: "audio/mp4", actual: 99, expected: 100))
        XCTAssertThrowsError(try DownloadValidation.check(status: 200, mime: "audio/mp4", actual: 0, expected: 0))
        XCTAssertThrowsError(try PlexBooks.tracks([]))
    }
    func testResumeRequestRejectsDifferentHostAndCredential() throws {
        let url = URL(string: "https://media.example.invalid/audio.mp3")!
        let request = try PlexTransport.request(url: url, token: "synthetic-old")
        let archived = try NSKeyedArchiver.archivedData(withRootObject: request as NSURLRequest, requiringSecureCoding: true)
        let resume = try PropertyListSerialization.data(fromPropertyList: ["NSURLSessionResumeOriginalRequest": archived], format: .binary, options: 0)
        XCTAssertTrue(Downloads.resumeMatches(resume, request: request))
        var changedHost = request; changedHost.url = URL(string: "https://other.example.invalid/audio.mp3")!
        XCTAssertFalse(Downloads.resumeMatches(resume, request: changedHost))
        let changedToken = try PlexTransport.request(url: url, token: "synthetic-new")
        XCTAssertFalse(Downloads.resumeMatches(resume, request: changedToken))
        XCTAssertFalse(Downloads.resumeMatches(Data(), request: request))
    }
    @MainActor func testTwoBooksRelaunchRewindDownloadAndMetadataEdit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        let a = try library.upsert(title: "Synthetic One", source: sampleSource("server-one", key: "1"))
        let b = try library.upsert(title: "Synthetic Two", source: sampleSource("server-one", key: "2"))
        let other = try library.upsert(title: "Synthetic One", source: sampleSource("server-two", key: "1"))
        XCTAssertNotEqual(a.identity, other.identity)
        library.record(a.id, position: 27.125, track: 1, offset: 7.125, chapter: "chapter-two")
        library.record(b.id, position: 8.5, track: 0, offset: 8.5)
        library.record(a.id, position: 24.25, track: 1, offset: 4.25, chapter: "chapter-two") // intentional rewind wins
        library.update(a.id) { book in
            book.title = "Corrected synthetic title"
            book.plex?.tracks[0].filename = "synthetic-one.mp3"
            book.plex?.tracks[1].filename = "synthetic-two.mp3"
            book.finished = true
        }
        let restored = Library(root: root)
        let first = try XCTUnwrap(restored.books.first { $0.id == a.id })
        let second = try XCTUnwrap(restored.books.first { $0.id == b.id })
        XCTAssertEqual(first.identity, a.identity)
        XCTAssertEqual(first.position, 24.25)
        XCTAssertEqual(first.progress?.offset, 4.25)
        XCTAssertEqual(first.progress?.trackIndex, 1)
        XCTAssertEqual(first.progress?.chapterID, "chapter-two")
        XCTAssertEqual(second.position, 8.5)
        XCTAssertTrue(first.offline)
        restored.remove(first)
        let removed = try XCTUnwrap(restored.books.first { $0.id == a.id })
        XCTAssertEqual(removed.position, 24.25); XCTAssertFalse(removed.offline)
    }
    @MainActor func testLegacyIndexMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let data = Data("[{\"id\":\"\(id)\",\"title\":\"Synthetic import\",\"filename\":\"synthetic.mp3\",\"position\":12.75}]".utf8)
        try data.write(to: root.appendingPathComponent("index.json"))
        let library = Library(root: root)
        XCTAssertEqual(library.books.first?.id, id)
        XCTAssertEqual(library.books.first?.position, 12.75)
        library.save()
        XCTAssertEqual(Library(root: root).books.first?.filename, "synthetic.mp3")
    }
    @MainActor func testPlayerSwitchesBooksWithoutResettingEitherCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        // Generate silent test audio at runtime; no audiobook fixture enters source or IPA.
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240_000)!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame] = 0 }
        let a = Book(id: UUID(), title: "Synthetic A", filename: "synthetic-a.wav", position: 7.125)
        let b = Book(id: UUID(), title: "Synthetic B", filename: "synthetic-b.wav", position: 12.5)
        for book in [a, b] {
            let file = try AVAudioFile(forWriting: root.appendingPathComponent(book.filename), settings: format.settings)
            try file.write(from: buffer)
        }
        library.books = [a, b]; library.save()
        let player = Player(library: library)
        player.open(a, autoplay: false)
        player.open(b, autoplay: false)
        player.pause()
        let restored = Library(root: root)
        XCTAssertEqual(restored.books.first(where: { $0.id == a.id })?.progress?.offset, 7.125)
        XCTAssertEqual(restored.books.first(where: { $0.id == b.id })?.progress?.offset, 12.5)
        XCTAssertEqual(restored.books.first(where: { $0.id == a.id })?.position, 7.125)
        XCTAssertEqual(restored.books.first(where: { $0.id == b.id })?.position, 12.5)
    }
    func testKeychainRoundTripAndDelete() throws {
        let key = "test-" + UUID().uuidString
        defer { try? SecureSettings.write("", key: key) }
        try SecureSettings.write("synthetic-test-value", key: key)
        XCTAssertFalse(SecureSettings.read(key).isEmpty)
        try SecureSettings.write("", key: key)
        XCTAssertTrue(SecureSettings.read(key).isEmpty)
    }
    private func sampleTrack(_ id: String, duration: Double) -> BookTrack {
        BookTrack(id: id, title: "Synthetic track", key: "/library/parts/1/audio.mp3", duration: duration, bytes: 100, ext: "mp3")
    }
    private func sampleSource(_ server: String, key: String) -> PlexBookSource {
        PlexBookSource(serverID: server, ratingKey: key, tracks: [sampleTrack("one", duration: 20), sampleTrack("two", duration: 10)])
    }
}
