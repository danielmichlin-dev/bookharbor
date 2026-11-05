import XCTest
import AVFoundation
@testable import BookHarbor

final class BookshelfPlaybackTests: XCTestCase {
    func testInitialRestoreWaitsForReadinessAndRunsOnce() {
        var preparation = PlaybackPreparation(offset: 42.125)
        XCTAssertFalse(preparation.ready)
        XCTAssertNil(preparation.requestSeek(18.25))
        XCTAssertFalse(preparation.restoreIssued)
        XCTAssertEqual(preparation.becameReady(), 18.25)
        XCTAssertNil(preparation.becameReady())
        XCTAssertEqual(preparation.requestSeek(4.75), 4.75)
    }
    func testValidShortRangeWasRejectedByLegacyExactEndCheck() throws {
        let response = HTTPURLResponse(url: URL(string: "https://media.example.invalid/audio")!, statusCode: 206,
            httpVersion: nil, headerFields: ["Content-Range": "bytes 0-4095/20000"])!
        // The old loader demanded "bytes 0-16383/20000" and rejected this
        // internally consistent, shorter response instead of continuing.
        XCTAssertNotEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 0-16383/20000")
        XCTAssertEqual(try MediaRange.validate(response, count: 4096, offset: 0, last: 16383, total: 20000), 4096)
        XCTAssertThrowsError(try MediaRange.validate(response, count: 4095, offset: 0, last: 16383, total: 20000))
        XCTAssertThrowsError(try MediaRange.validate(response, count: 4096, offset: 5, last: 16383, total: 20000))
        XCTAssertThrowsError(try MediaRange.validate(response, count: 4096, offset: 0, last: 16383, total: 19999))
        XCTAssertEqual(try MediaRange.end(offset: 19900, length: 1000, allToEnd: false, total: 20000), 20000)
        XCTAssertThrowsError(try MediaRange.end(offset: -1, length: 1, allToEnd: false, total: 20000))
    }
    @MainActor func testAutomaticPagesPopulateShelfWithoutTrackOrAudioRequests() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        let imported = Book(id: UUID(), title: "Synthetic import", filename: "synthetic.mp3", position: 12.5)
        library.books = [imported]; library.save()
        var starts: [Int] = []
        let plex = PlexClient(library: library, containerFetch: { key, _, _, start in
            XCTAssertEqual(key, "/library/sections/7/all")
            starts.append(start)
            let range = start == 0 ? 0..<50 : 50..<51
            let albums = range.map { PlexMetadata(ratingKey: String($0), title: "Synthetic \($0)", parentTitle: "Synthetic Author") }
            return PlexContainer(offset: start, size: albums.count, totalSize: 51, Metadata: albums)
        })
        plex.linked = true; plex.selectedServer = "synthetic-server"
        await plex.selectLibrary(PlexDirectory(key: "7", title: "Synthetic library", type: "artist"))
        XCTAssertEqual(starts, [0, 50])
        XCTAssertEqual(library.books.count, 52)
        XCTAssertTrue(library.books.filter { $0.plex != nil }.allSatisfy { $0.tracks.isEmpty && !$0.offline })
        XCTAssertEqual(library.selection, ShelfSelection(serverID: "synthetic-server", libraryID: "7"))
        await plex.refreshShelf()
        XCTAssertEqual(library.books.count, 52)
        let restored = Library(root: root)
        XCTAssertEqual(restored.books.count, 52)
        XCTAssertEqual(restored.books.first { $0.id == imported.id }?.position, 12.5)
        XCTAssertEqual(Bookshelf.filtered(restored.books, query: "Author", selection: restored.selection, scope: "Library").count, 51)
        XCTAssertEqual(Bookshelf.filtered(restored.books, query: "", selection: restored.selection, scope: "Imports").count, 1)
    }
    @MainActor func testMetadataRefreshPreservesDownloadedAudioChapterAndRewind() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        var track = sampleTrack(bytes: 100); track.filename = "synthetic.wav"
        let source = PlexBookSource(serverID: "synthetic-server", ratingKey: "7", tracks: [track], libraryID: "9")
        let book = try library.upsert(title: "Synthetic original", source: source)
        library.record(book.id, position: 9, offset: 9)
        library.record(book.id, position: 2.125, offset: 2.125, chapter: "synthetic-chapter")
        library.update(book.id) { $0.finished = true; $0.importedChapters = [BookChapter(id: "synthetic-chapter", title: "Synthetic", trackIndex: 0, start: 1, end: 5)] }
        try library.mergeAlbums([PlexMetadata(ratingKey: "7", title: "Synthetic corrected", parentTitle: "Synthetic author")], server: "synthetic-server", library: "9")
        let restored = try XCTUnwrap(Library(root: root).books.first)
        XCTAssertEqual(restored.id, book.id); XCTAssertEqual(restored.identity, book.identity)
        XCTAssertEqual(restored.title, "Synthetic corrected")
        XCTAssertEqual(restored.tracks.first?.filename, "synthetic.wav")
        XCTAssertEqual(restored.progress?.offset, 2.125)
        XCTAssertEqual(restored.progress?.chapterID, "synthetic-chapter")
        XCTAssertEqual(restored.importedChapters?.count, 1); XCTAssertEqual(restored.finished, true)
    }
    func testSourceChoiceDistinguishesUnresolvedPartialAndComplete() {
        var book = Book(id: UUID(), title: "Synthetic", filename: "", plex: PlexBookSource(serverID: "s", ratingKey: "1", tracks: []))
        XCTAssertEqual(Bookshelf.source(for: book), .unresolved); XCTAssertFalse(book.offline)
        book.plex?.tracks = [sampleTrack(bytes: 100), sampleTrack(bytes: 100)]
        book.plex?.tracks[0].filename = "synthetic-one.wav"
        XCTAssertEqual(Bookshelf.source(for: book), .streaming); XCTAssertTrue(book.hasPartialDownload)
        book.plex?.tracks[1].filename = "synthetic-two.wav"
        XCTAssertEqual(Bookshelf.source(for: book), .downloaded)
        XCTAssertEqual(Bookshelf.source(for: Book(id: UUID(), title: "Synthetic", filename: "synthetic.wav")), .imported)
    }
    @MainActor func testRemoveDownloadKeepsBookMetadataAndProgressAfterRelaunch() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        try Data(repeating: 0, count: 100).write(to: root.appendingPathComponent("synthetic.wav"))
        var track = sampleTrack(bytes: 100); track.filename = "synthetic.wav"
        let book = try library.upsert(title: "Synthetic", source: PlexBookSource(serverID: "s", ratingKey: "1", tracks: [track]))
        library.record(book.id, position: 2.125, offset: 2.125, chapter: "synthetic-chapter")
        library.remove(library.books[0])
        let restored = try XCTUnwrap(Library(root: root).books.first)
        XCTAssertEqual(restored.id, book.id); XCTAssertEqual(restored.position, 2.125)
        XCTAssertEqual(restored.progress?.chapterID, "synthetic-chapter")
        XCTAssertFalse(restored.offline)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("synthetic.wav").path))
    }
    @MainActor func testCustomNetworkAssetBecomesReadyRestoresAndPlays() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        let audio = try silentWAV(root: root)
        let source = PlexBookSource(serverID: "synthetic-server", ratingKey: "1", tracks: [sampleTrack(bytes: Int64(audio.count))])
        let book = try library.upsert(title: "Synthetic remote", source: source)
        library.record(book.id, position: 2.125, offset: 2.125)
        var requests = 0
        let player = Player(library: library, remoteRequest: { _, _ in try self.syntheticRequest() }, fetch: { request, _ in
            requests += 1
            return try self.rangeReply(request, audio: audio)
        })
        defer { player.close() }
        player.open(library.books[0], autoplay: false)
        XCTAssertEqual(player.state, .loading)
        await waitUntil { player.state == .paused || player.state == .failed }
        XCTAssertEqual(player.state, .paused, player.diagnostics.text)
        XCTAssertGreaterThan(requests, 0)
        XCTAssertTrue(player.diagnostics.events.contains { $0.stage == .readiness && $0.fact == .ready })
        XCTAssertTrue(player.diagnostics.events.contains { $0.stage == .seek && $0.fact == .complete })
        player.save(); XCTAssertEqual(library.books[0].position, 2.125, accuracy: 0.05)
        player.play()
        await waitUntil { player.state == .playing || player.state == .failed }
        XCTAssertEqual(player.state, .playing, player.diagnostics.text)
        player.pause()
        player.jump(BookChapter(id: "synthetic-chapter", title: "Synthetic", trackIndex: 0, start: 4.25, end: 7))
        await waitUntil { player.state == .paused || player.state == .failed }
        player.save(); XCTAssertEqual(library.books[0].position, 4.25, accuracy: 0.05)
    }
    @MainActor func testCompletedDownloadBypassesNetworkAndLocalPlayerStillPrepares() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        let audio = try silentWAV(root: root)
        var track = sampleTrack(bytes: Int64(audio.count)); track.filename = "synthetic.wav"
        let book = try library.upsert(title: "Synthetic local", source: PlexBookSource(serverID: "s", ratingKey: "1", tracks: [track]))
        let player = Player(library: library, remoteRequest: { _, _ in XCTFail("Completed download must not resolve a network request"); return try self.syntheticRequest() })
        defer { player.close() }
        player.open(book, autoplay: false)
        await waitUntil { player.state == .paused || player.state == .failed }
        XCTAssertEqual(player.state, .paused, player.diagnostics.text)
        XCTAssertTrue(player.diagnostics.events.contains { $0.stage == .source && $0.fact == .local })
    }
    @MainActor func testHTTPFailureIsVisibleAndDiagnosticContainsNoPrivateValues() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        let book = try library.upsert(title: "Synthetic private title", source: PlexBookSource(serverID: "s", ratingKey: "1", tracks: [sampleTrack(bytes: 100)]))
        library.record(book.id, position: 2.125, offset: 2.125)
        let player = Player(library: library, remoteRequest: { _, _ in try self.syntheticRequest() }, fetch: { _, _ in throw PlexError.http(401) })
        defer { player.close() }
        player.open(library.books[0])
        await waitUntil { player.state == .failed }
        XCTAssertEqual(player.state, .failed)
        XCTAssertTrue(player.message.contains("401"))
        XCTAssertTrue(player.diagnostics.text.contains("code 401"))
        for value in [book.title, "media.example.invalid", "synthetic-token", "2.125"] { XCTAssertFalse(player.diagnostics.text.contains(value)) }
        XCTAssertEqual(library.books[0].position, 2.125)
    }
    @MainActor func testM4BStyleAACContainerPreparesThroughNetworkLoader() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = 0 }
        let fileURL = root.appendingPathComponent("synthetic.m4a")
        do {
            let file = try AVAudioFile(forWriting: fileURL, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
            try file.write(from: buffer)
        }
        let audio = try Data(contentsOf: fileURL)
        var track = sampleTrack(bytes: Int64(audio.count)); track.ext = "m4b"
        let book = try library.upsert(title: "Synthetic M4B container", source: PlexBookSource(serverID: "s", ratingKey: "1", tracks: [track]))
        let player = Player(library: library, remoteRequest: { _, _ in try self.syntheticRequest() }, fetch: { request, _ in
            try self.rangeReply(request, audio: audio, mime: "audio/mp4")
        })
        defer { player.close() }
        player.open(book, autoplay: false)
        await waitUntil { player.state == .paused || player.state == .failed }
        XCTAssertEqual(player.state, .paused, player.diagnostics.text)
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Playback condition timed out")
    }
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func syntheticRequest() throws -> URLRequest {
        try PlexTransport.request(url: URL(string: "https://media.example.invalid/library/parts/1/audio.wav")!, token: "synthetic-token")
    }
    private func sampleTrack(bytes: Int64) -> BookTrack {
        BookTrack(id: "synthetic-track", title: "Synthetic track", key: "/library/parts/1/audio.wav", duration: 12, bytes: bytes, ext: "wav")
    }
    private func silentWAV(root: URL) throws -> Data {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = 0 }
        do {
            let file = try AVAudioFile(forWriting: root.appendingPathComponent("synthetic.wav"), settings: format.settings)
            try file.write(from: buffer)
        }
        return try Data(contentsOf: root.appendingPathComponent("synthetic.wav"))
    }
    private func rangeReply(_ request: URLRequest, audio: Data, mime: String = "audio/wav") throws -> (Data, HTTPURLResponse) {
        let range = try XCTUnwrap(request.value(forHTTPHeaderField: "Range")).replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
        let start = try XCTUnwrap(Int(range[0])); let requestedEnd = try XCTUnwrap(Int(range[1]))
        let end = min(requestedEnd, start + 8191, audio.count - 1)
        let data = audio.subdata(in: start..<(end + 1))
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil,
            headerFields: ["Content-Range": "bytes \(start)-\(end)/\(audio.count)", "Content-Type": mime, "Content-Length": String(data.count)])!
        return (data, response)
    }
}
