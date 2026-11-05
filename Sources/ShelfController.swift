import Foundation
import Combine

@MainActor final class ShelfController: ObservableObject {
    let library: Library
    let plex: PlexClient
    let player: Player
    let downloads: Downloads
    @Published private(set) var resolving = Set<UUID>()
    @Published private(set) var selectedBookID: UUID?
    private var selectionTask: Task<Void, Never>?
    private var selection = UUID()
    init(library: Library, plex: PlexClient, player: Player, downloads: Downloads) {
        self.library = library; self.plex = plex; self.player = player; self.downloads = downloads
    }
    func play(_ book: Book, jump: BookChapter? = nil) {
        selectionTask?.cancel(); selection = UUID(); let token = selection
        selectedBookID = book.id
        player.prepareSelection()
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.player.diagnostics.record(.metadata, .started)
                let latest = self.library.books.first { $0.id == book.id } ?? book
                let resolved = try await self.plex.resolve(latest, library: self.library)
                try Task.checkCancellation()
                guard self.selection == token else { return }
                self.player.diagnostics.record(.metadata, .complete)
                self.player.open(resolved, resetDiagnostics: false)
                if let jump { self.player.jump(jump) }
            } catch is CancellationError { return }
            catch {
                guard self.selection == token else { return }
                self.player.diagnostics.record(.metadata, .failed)
                self.player.failSelection(error)
            }
        }
    }
    func download(_ book: Book) {
        guard !resolving.contains(book.id) else { return }
        resolving.insert(book.id)
        Task {
            defer { resolving.remove(book.id) }
            do {
                let latest = library.books.first { $0.id == book.id } ?? book
                let resolved = try await plex.resolve(latest, library: library)
                downloads.start(resolved)
            } catch { downloads.message = (error as? PlexError)?.errorDescription ?? "Could not resolve this download. Please retry." }
        }
    }
    func cancelSelection() { selectionTask?.cancel(); selection = UUID(); player.pause() }
    func removeDownload(_ book: Book) async {
        await downloads.cancel(book.id, resumable: false)
        let latest = library.books.first { $0.id == book.id } ?? book
        if player.book?.id == book.id { player.close() }
        if selectedBookID == book.id { selectedBookID = nil }
        library.remove(latest)
    }
}
