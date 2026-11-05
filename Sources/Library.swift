import Foundation
import Combine

struct Book: Identifiable, Codable {
    let id: UUID
    var title: String
    let filename: String
    var position: Double = 0
    var plex: PlexBookSource?
    var progress: ListeningProgress?
    var finished: Bool?
    var artworkFile: String?
    var importedChapters: [BookChapter]?
    var identity: String { plex?.identity ?? id.uuidString }
    var offline: Bool { plex == nil || plex?.tracks.allSatisfy { $0.filename != nil } == true }
    var tracks: [BookTrack] { plex?.tracks ?? [] }
}

struct ListeningProgress: Codable {
    var trackID: String?
    var trackIndex: Int
    var offset: Double
    var chapterID: String?
    var updatedAt: Date
}

struct BookChapter: Codable, Identifiable {
    var id: String
    var title: String
    var trackIndex: Int
    var start: Double
    var end: Double
    var duration: Double { max(0, end - start) }
}

enum BookTimeline {
    static func location(_ position: Double, tracks: [BookTrack]) -> (Int, Double) {
        var remaining = max(0, position)
        for (index, track) in tracks.enumerated() {
            if remaining < track.duration || index == tracks.count - 1 { return (index, min(remaining, track.duration)) }
            remaining -= track.duration
        }
        return (0, remaining)
    }
    static func absolute(track: Int, offset: Double, tracks: [BookTrack]) -> Double {
        tracks.prefix(max(0, track)).reduce(0) { $0 + $1.duration } + max(0, offset)
    }
    static func chapters(_ source: [PlexChapter], track: Int, duration: Double) -> [BookChapter] {
        let sorted = source.sorted { $0.startTimeOffset < $1.startTimeOffset }
        return sorted.enumerated().compactMap { index, chapter in
            let start = chapter.startTimeOffset / 1000
            let next = index + 1 < sorted.count ? sorted[index + 1].startTimeOffset / 1000 : duration
            let end = min(duration, chapter.endTimeOffset.map { $0 / 1000 } ?? next, next)
            guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
            return BookChapter(id: "\(track):\(start)", title: chapter.tag ?? "Chapter \(index + 1)", trackIndex: track, start: start, end: end)
        }
    }
}

@MainActor final class Library: ObservableObject {
    @Published var books: [Book] = []
    @Published var message = ""
    let root: URL
    private var canWrite = true
    init(root supplied: URL? = nil) {
        root = supplied ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Books", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var folder = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            let index = root.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: index.path) {
                books = try JSONDecoder().decode([Book].self, from: Data(contentsOf: index))
            }
        } catch {
            canWrite = false
            message = "Could not load the local library. Your files have not been deleted. Reopen after unlocking; writes are disabled to protect your index."
        }
    }
    func url(for book: Book) -> URL { root.appendingPathComponent(book.filename) }
    @discardableResult func save() -> Bool {
        guard canWrite else { return false }
        do {
            let data = try JSONEncoder().encode(books)
            try data.write(to: root.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { message = "Could not save your listening progress. Check available storage."; return false }
    }
    func importFile(_ source: URL) {
        guard canWrite else { return }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        guard ["m4b", "m4a", "mp3", "aac", "wav"].contains(ext) else {
            message = "Choose an M4B, M4A, MP3, AAC, or WAV file."; return
        }
        let id = UUID()
        let name = id.uuidString + "." + ext
        let destination = root.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            books.append(Book(id: id, title: source.deletingPathExtension().lastPathComponent, filename: name))
            save()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            message = "Import failed. Check file access and free storage, then retry."
        }
    }
    func record(_ id: UUID, position: Double, track: Int = 0, offset: Double? = nil, chapter: String? = nil) {
        guard canWrite, position.isFinite, offset?.isFinite != false, let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].position = max(0, position)
        books[index].progress = ListeningProgress(trackID: books[index].tracks.indices.contains(track) ? books[index].tracks[track].id : nil,
            trackIndex: track, offset: max(0, offset ?? position), chapterID: chapter, updatedAt: Date())
        save()
    }
    func remove(_ book: Book) {
        guard canWrite else { return }
        do {
            if book.plex != nil {
                for track in book.tracks { if let file = track.filename { try? FileManager.default.removeItem(at: root.appendingPathComponent(file)) } }
                if let index = books.firstIndex(where: { $0.id == book.id }) {
                    for track in books[index].plex!.tracks.indices { books[index].plex!.tracks[track].filename = nil }
                }
            } else {
                try FileManager.default.removeItem(at: url(for: book))
                books.removeAll { $0.id == book.id }
            }
            save()
        } catch { message = "Could not delete this book." }
    }
    func upsert(title: String, source: PlexBookSource) throws -> Book {
        guard canWrite else { throw PlexError.storage }
        if let existing = books.first(where: { $0.identity == source.identity }) { return existing }
        let book = Book(id: UUID(), title: title, filename: "", plex: source)
        books.append(book)
        guard save() else { books.removeLast(); throw PlexError.storage }
        return book
    }
    @discardableResult func update(_ id: UUID, _ edit: (inout Book) -> Void) -> Bool {
        guard canWrite, let index = books.firstIndex(where: { $0.id == id }) else { return false }
        let old = books[index]
        edit(&books[index])
        guard save() else { books[index] = old; return false }
        return true
    }
    var storageBytes: Int64 {
        var total: Int64 = 0
        for book in books {
            let files = book.plex == nil ? [book.filename] : book.tracks.compactMap(\.filename)
            for file in files {
                let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(file).path)
                total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return total
    }
}
