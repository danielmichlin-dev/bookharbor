import Foundation
import Combine

struct Book: Identifiable, Codable {
    let id: UUID
    var title: String
    let filename: String
    var position: Double = 0
}

@MainActor final class Library: ObservableObject {
    @Published var books: [Book] = []
    @Published var message = ""
    let root: URL
    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
        } catch { message = "Could not load the local library. Your files have not been deleted." }
    }
    func url(for book: Book) -> URL { root.appendingPathComponent(book.filename) }
    func save() {
        do {
            let data = try JSONEncoder().encode(books)
            try data.write(to: root.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { message = "Could not save your listening progress. Check available storage." }
    }
    func importFile(_ source: URL) {
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
    func record(_ id: UUID, position: Double) {
        guard position.isFinite, let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].position = max(0, position)
        save()
    }
    func remove(_ book: Book) {
        do {
            try FileManager.default.removeItem(at: url(for: book))
            books.removeAll { $0.id == book.id }
            save()
        } catch { message = "Could not delete this book." }
    }
}
