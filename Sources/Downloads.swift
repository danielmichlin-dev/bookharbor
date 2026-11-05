import Foundation
import AVFoundation
import Combine
import UIKit

struct DownloadJob: Codable, Identifiable {
    var id: UUID { bookID }
    var bookID: UUID
    var track: Int
    var tag: String
    var state: String
    var resumeFile: String?
}

@MainActor final class Downloads: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let identifier = "org.example.bookharbor.downloads"
    @Published var jobs: [DownloadJob] = []
    @Published var fractions: [UUID: Double] = [:]
    @Published var message = ""
    nonisolated let root: URL
    private let library: Library
    private let plex: PlexClient
    private var ready = false
    private var validating = 0
    private var eventsFinished = false
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.urlCache = nil; config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    init(library: Library, plex: PlexClient) {
        self.library = library; self.plex = plex; root = library.root
        super.init()
        if let data = try? Data(contentsOf: root.appendingPathComponent("downloads.json")) {
            do { jobs = try JSONDecoder().decode([DownloadJob].self, from: data) }
            catch { message = "Download queue could not be restored. Completed books remain available." }
        }
        _ = session
        Task { await restore() }
    }
    private func persist() {
        do {
            try JSONEncoder().encode(jobs).write(to: root.appendingPathComponent("downloads.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { message = "Could not save the download queue. Check free storage." }
    }
    private func restore() async {
        let tasks = await session.allTasks
        for task in tasks {
            guard let job = jobs.first(where: { $0.tag == task.taskDescription }),
                  let book = library.books.first(where: { $0.id == job.bookID }),
                  let source = book.plex, source.tracks.indices.contains(job.track),
                  let request = try? plex.mediaRequest(source: source, track: source.tracks[job.track]),
                  request.url == task.originalRequest?.url,
                  request.value(forHTTPHeaderField: "X-Plex-Token") == task.originalRequest?.value(forHTTPHeaderField: "X-Plex-Token") else { task.cancel(); continue }
        }
        for index in jobs.indices where jobs[index].state == "Downloading" {
            if !tasks.contains(where: { $0.taskDescription == jobs[index].tag }) { jobs[index].state = "Interrupted — retry" }
        }
        ready = true; persist()
    }
    func start(_ book: Book) {
        guard ready else { message = "Restoring downloads. Please try again in a moment."; return }
        guard let source = book.plex, !book.offline else { return }
        guard !jobs.contains(where: { $0.bookID == book.id && $0.state == "Downloading" }) else { return }
        guard let track = source.tracks.firstIndex(where: { $0.filename == nil }) else { return }
        let previous = jobs.first(where: { $0.bookID == book.id })
        jobs.removeAll { $0.bookID == book.id }
        jobs.append(DownloadJob(bookID: book.id, track: track, tag: UUID().uuidString, state: "Preparing", resumeFile: previous?.resumeFile))
        schedule(book.id)
    }
    private func schedule(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.bookID == id }),
              let book = library.books.first(where: { $0.id == id }), let source = book.plex,
              source.tracks.indices.contains(jobs[index].track) else { return }
        do {
            let remaining = source.tracks.filter { $0.filename == nil }.reduce(Int64(0)) { $0 + $1.bytes }
            let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            // Account for temporary transfer storage and finalization headroom.
            guard available > remaining + source.tracks[jobs[index].track].bytes + 32 * 1024 * 1024 else { throw PlexError.storage }
            let request = try plex.mediaRequest(source: source, track: source.tracks[jobs[index].track])
            let task: URLSessionDownloadTask
            if let file = jobs[index].resumeFile, let data = try? Data(contentsOf: root.appendingPathComponent(file)),
               Self.resumeMatches(data, request: request) {
                task = session.downloadTask(withResumeData: data)
            } else { task = session.downloadTask(with: request) }
            if let file = jobs[index].resumeFile { try? FileManager.default.removeItem(at: root.appendingPathComponent(file)) }
            jobs[index].resumeFile = nil
            jobs[index].state = "Downloading"
            task.taskDescription = jobs[index].tag
            persist(); task.resume()
        } catch {
            jobs[index].state = "Retry needed"
            message = (error as? PlexError)?.errorDescription ?? "Could not start this download."
            persist()
        }
    }
    nonisolated static func resumeMatches(_ data: Data, request: URLRequest) -> Bool {
        guard let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let archived = info["NSURLSessionResumeOriginalRequest"] as? Data,
              let old = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURLRequest.self, from: archived) else { return false }
        return old.url == request.url && old.value(forHTTPHeaderField: "X-Plex-Token") == request.value(forHTTPHeaderField: "X-Plex-Token")
    }
    func cancel(_ id: UUID, resumable: Bool = true) async {
        guard let index = jobs.firstIndex(where: { $0.bookID == id }) else { return }
        let tag = jobs[index].tag
        jobs[index].tag = UUID().uuidString // Ignore late completion and validation callbacks.
        jobs[index].state = resumable ? "Paused — retry to resume" : "Cancelled"
        if !resumable, let file = jobs[index].resumeFile {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(file)); jobs[index].resumeFile = nil
        }
        let replacement = jobs[index].tag
        persist()
        for task in await session.allTasks where task.taskDescription == tag {
            if resumable, let download = task as? URLSessionDownloadTask {
                let data = await download.cancelByProducingResumeData()
                if let data, let current = jobs.firstIndex(where: { $0.bookID == id && $0.tag == replacement }) {
                    let file = "resume-" + UUID().uuidString
                    do {
                        try data.write(to: root.appendingPathComponent(file), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                        jobs[current].resumeFile = file
                    } catch { message = "Resume data could not be saved. Retry will start this track again." }
                }
            } else { task.cancel() }
        }
        persist()
    }
    func signOut() async {
        for id in jobs.map(\.bookID) { await cancel(id, resumable: false) }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The delegate's temporary file must be moved before returning.
        let staged = root.appendingPathComponent("pending-" + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staged.path)
        } catch {
            Task { @MainActor in self.fail(downloadTask.taskDescription, error: PlexError.storage) }; return
        }
        let tag = downloadTask.taskDescription
        let response = downloadTask.response as? HTTPURLResponse
        Task { @MainActor in await self.finish(tag: tag, response: response, staged: staged) }
    }
    private func finish(tag: String?, response: HTTPURLResponse?, staged: URL) async {
        validating += 1
        defer {
            try? FileManager.default.removeItem(at: staged)
            validating -= 1
            completeEventsIfReady()
        }
        guard let job = jobs.first(where: { $0.tag == tag && $0.state == "Downloading" }),
              let book = library.books.first(where: { $0.id == job.bookID }),
              let source = book.plex, source.tracks.indices.contains(job.track) else { return }
        let track = source.tracks[job.track]
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.int64Value ?? 0
            try DownloadValidation.check(status: response?.statusCode ?? 0, mime: response?.mimeType, actual: size, expected: track.bytes)
            let asset = AVURLAsset(url: staged)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard !audio.isEmpty else { throw PlexError.incomplete }
            guard let index = jobs.firstIndex(where: { $0.tag == tag && $0.state == "Downloading" }) else { return }
            let file = UUID().uuidString + "." + track.ext
            try FileManager.default.moveItem(at: staged, to: root.appendingPathComponent(file))
            library.update(book.id) { $0.plex?.tracks[job.track].filename = file }
            if let next = library.books.first(where: { $0.id == book.id })?.tracks.firstIndex(where: { $0.filename == nil }) {
                jobs[index].track = next; jobs[index].tag = UUID().uuidString
                persist(); schedule(book.id)
            } else {
                jobs.remove(at: index); fractions[book.id] = nil; persist()
                message = "Download complete. This book is ready offline."
            }
        } catch { fail(tag, error: error) }
    }
    private func fail(_ tag: String?, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.tag == tag }) else { return }
        jobs[index].state = "Retry needed"; persist()
        message = (error as? PlexError)?.errorDescription ?? "Transfer failed. Check your connection and retry."
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let tag = task.taskDescription
        Task { @MainActor in
            guard let index = self.jobs.firstIndex(where: { $0.tag == tag }) else { return }
            if let resume {
                let file = "resume-" + UUID().uuidString
                if (try? resume.write(to: self.root.appendingPathComponent(file), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil {
                    self.jobs[index].resumeFile = file
                }
            }
            self.fail(tag, error: PlexError.unavailable)
        }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let tag = downloadTask.taskDescription
        Task { @MainActor in
            guard let job = self.jobs.first(where: { $0.tag == tag }),
                  let book = self.library.books.first(where: { $0.id == job.bookID }) else { return }
            let total = book.tracks.reduce(Int64(0)) { $0 + $1.bytes }
            let done = book.tracks.filter { $0.filename != nil }.reduce(Int64(0)) { $0 + $1.bytes }
            self.fractions[book.id] = min(1, Double(done + totalBytesWritten) / Double(max(1, total)))
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.eventsFinished = true; self.completeEventsIfReady() }
    }
    private func completeEventsIfReady() {
        if eventsFinished && validating == 0 {
            eventsFinished = false
            AppDelegate.completeBackgroundEvents()
        }
    }
}

@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundCompletion: (() -> Void)?
    static var reconnect: (() -> Void)?
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Downloads.identifier else { completionHandler(); return }
        Self.backgroundCompletion = completionHandler
        Self.reconnect?()
    }
    static func completeBackgroundEvents() {
        let completion = backgroundCompletion; backgroundCompletion = nil; completion?()
    }
}
