import SwiftUI
import UniformTypeIdentifiers
import ImageIO

struct ContentView: View {
    @ObservedObject var library: Library
    @ObservedObject var player: Player
    @ObservedObject var plex: PlexClient
    @ObservedObject var downloads: Downloads
    @ObservedObject var shelf: ShelfController
    @State private var query = ""
    @State private var scope = "Library"
    @State private var importing = false
    @State private var settings = false
    @State private var details: Book?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Books", selection: $scope) {
                        ForEach(["Library", "Downloads", "Imports"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented)
                    shelfContents
                    if plex.busy { ProgressView("Refreshing bookshelf…") }
                    if !plex.status.isEmpty { Text(plex.status).font(.caption).foregroundStyle(.secondary) }
                    if !library.message.isEmpty { Text(library.message).font(.caption) }
                    if !downloads.message.isEmpty { Text(downloads.message).font(.caption) }
                }.padding()
            }
            .navigationTitle("Bookshelf")
            .searchable(text: $query, prompt: "Title or author")
            .refreshable { await plex.refreshShelf() }
            .task { await plex.refreshShelf() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Plex & Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Label("Import audio", systemImage: "plus") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let book = selectedBook { PlayerPanel(book: book, player: player, shelf: shelf, downloads: downloads) }
            }
            .sheet(isPresented: $settings) { PlexView(plex: plex, library: library, player: player, downloads: downloads, shelf: shelf) }
            .sheet(item: $details) { book in BookDetailsView(bookID: book.id, library: library, shelf: shelf, downloads: downloads, player: player) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, UTType(filenameExtension: "m4b") ?? .audio]) { result in
                switch result {
                case .success(let url): library.importFile(url)
                case .failure: library.message = "Import was not completed."
                }
            }
        }.tint(.teal)
    }
    private var selectedBook: Book? {
        let id = shelf.selectedBookID ?? player.book?.id
        return library.books.first { $0.id == id }
    }
    @ViewBuilder private var shelfContents: some View {
        let books = Bookshelf.filtered(library.books, query: query, selection: library.selection, scope: scope)
        let continuing = books.filter { $0.position > 0 && $0.finished != true }.sorted {
            ($0.progress?.updatedAt ?? .distantPast) > ($1.progress?.updatedAt ?? .distantPast)
        }
        if !continuing.isEmpty {
            Text("Continue Listening").font(.title2.bold())
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(continuing) { book in card(book).frame(width: 145) }
                }
            }
        }
        Text(scope == "Library" ? "Your books" : scope).font(.title2.bold())
        if books.isEmpty {
            ContentUnavailableView(query.isEmpty ? "Your listening shelf" : "No matching books", systemImage: "books.vertical",
                description: Text(query.isEmpty ? "Choose your Plex library in Settings, or import audio from Files. Cached books remain browsable offline." : "Search matches cached titles and authors."))
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 18)], alignment: .leading, spacing: 22) {
            ForEach(books) { book in card(book) }
        }
    }
    private func card(_ book: Book) -> some View {
        BookCard(book: book, root: library.root, downloads: downloads,
            play: { shelf.play(book) }, details: { details = book }) {
                BookMenu(book: book, library: library, shelf: shelf, player: player, downloads: downloads)
            }
            .task(id: book.identity) { await plex.cacheArtwork(book) }
    }
}

struct CoverArtwork: View {
    let file: String?
    let root: URL
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.teal.opacity(0.12))
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "book.closed.fill").font(.largeTitle).foregroundStyle(.teal) }
        }.aspectRatio(0.78, contentMode: .fit).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
        .task(id: file) {
            guard let file else { image = nil; return }
            let url = root.appendingPathComponent(file)
            let decoded = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 480, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                return UIImage(cgImage: image)
            }.value
            if !Task.isCancelled { image = decoded }
        }
    }
}

struct BookCard<Actions: View>: View {
    let book: Book
    let root: URL
    @ObservedObject var downloads: Downloads
    let play: () -> Void
    let details: () -> Void
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: play) {
                VStack(alignment: .leading, spacing: 6) {
                    CoverArtwork(file: book.artworkFile, root: root)
                    Text(book.title).font(.headline).lineLimit(2).foregroundStyle(.primary)
                    Text(book.plex?.author ?? "Imported audio").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Play or resume this book")
            .contextMenu { actions() }
            ProgressView(value: book.totalDuration > 0 ? min(1, book.position / book.totalDuration) : 0)
            HStack {
                Text(book.finished == true ? "Finished" : audioClock(book.position)).font(.caption2).monospacedDigit()
                Spacer()
                Image(systemName: book.offline ? "checkmark.circle.fill" : book.hasPartialDownload ? "circle.lefthalf.filled" : "icloud")
                    .foregroundStyle(book.offline ? .teal : .secondary)
                    .accessibilityLabel(book.offline ? "Available offline" : book.hasPartialDownload ? "Partial download" : "Connection needed")
                Button(action: details) { Image(systemName: "info.circle") }.accessibilityLabel("Book details")
            }
            if let job = downloads.jobs.first(where: { $0.bookID == book.id }) {
                ProgressView(value: downloads.fractions[book.id] ?? 0)
                Text(job.state).font(.caption2).lineLimit(2)
            }
        }
    }
}

struct BookMenu: View {
    let book: Book
    @ObservedObject var library: Library
    @ObservedObject var shelf: ShelfController
    @ObservedObject var player: Player
    @ObservedObject var downloads: Downloads
    var body: some View {
        if book.plex != nil {
            if !book.offline {
                Button("Download for offline listening") { shelf.download(book) }.disabled(shelf.resolving.contains(book.id))
            }
            if let job = downloads.jobs.first(where: { $0.bookID == book.id }) {
                if job.state == "Downloading" { Button("Pause download") { Task { await downloads.cancel(book.id) } } }
                else { Button("Retry / resume download") { shelf.download(book) } }
                Button("Cancel download") { Task { await downloads.cancel(book.id, resumable: false) } }
            }
            if book.offline || book.hasPartialDownload {
                Button("Remove download", role: .destructive) { Task { await shelf.removeDownload(book) } }
            }
        }
        Button(book.finished == true ? "Mark unfinished" : "Mark finished") { library.update(book.id) { $0.finished = !(book.finished ?? false) } }
        Button("Restart from beginning") {
            if player.book?.id == book.id { player.pause(); player.seek(0) }
            library.update(book.id) { $0.position = 0; $0.progress = nil; $0.finished = false }
        }
    }
}

struct PlayerPanel: View {
    let book: Book
    @ObservedObject var player: Player
    @ObservedObject var shelf: ShelfController
    @ObservedObject var downloads: Downloads
    @State private var chapters = false
    @State private var diagnostics = false
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(book.title).font(.headline).lineLimit(1)
                    Text("\(player.state.rawValue) | \(audioClock(player.elapsed)) / \(audioClock(player.duration))").font(.caption).monospacedDigit()
                }
                Spacer()
                if book.plex != nil {
                    Menu {
                        BookMenu(book: book, library: shelf.library, shelf: shelf, player: player, downloads: downloads)
                    } label: { Image(systemName: book.offline ? "checkmark.circle" : "arrow.down.circle") }.accessibilityLabel("Download controls")
                }
                Button { chapters = true } label: { Image(systemName: "list.bullet") }.accessibilityLabel("Chapters and tracks")
                    .disabled(player.book?.id != book.id)
                Button { diagnostics = true } label: { Image(systemName: "stethoscope") }.accessibilityLabel("Playback diagnostics")
            }
            if player.state == .loading || player.state == .buffering { ProgressView() }
            if let job = downloads.jobs.first(where: { $0.bookID == book.id }) {
                HStack {
                    ProgressView(value: downloads.fractions[book.id] ?? 0)
                    Text(job.state).font(.caption2)
                    Button("Cancel") { Task { await downloads.cancel(book.id, resumable: false) } }.font(.caption)
                }
            }
            if !player.message.isEmpty { Text(player.message).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
            HStack(spacing: 28) {
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                Button {
                    if [.playing, .buffering, .loading].contains(player.state) { shelf.cancelSelection() }
                    else { shelf.play(book) }
                } label: { Image(systemName: [.playing, .buffering, .loading].contains(player.state) ? "pause.circle.fill" : "play.circle.fill").font(.largeTitle) }
                .accessibilityLabel(player.state == .failed ? "Retry playback" : "Play or pause")
                Button { player.skip(30) } label: { Image(systemName: "goforward.30") }
                Spacer()
                Menu("\(player.speed, specifier: "%.2g")x") {
                    ForEach([0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { value in Button("\(value, specifier: "%.2g")x") { player.changeSpeed(Float(value)) } }
                }
                Menu(player.sleepMinutes > 0 ? "\(player.sleepMinutes)m" : "Sleep") {
                    ForEach([0, 15, 30, 45, 60], id: \.self) { value in Button(value == 0 ? "Off" : "\(value) minutes") { player.setSleep(value) } }
                }
            }
        }.padding().background(.regularMaterial)
        .sheet(isPresented: $chapters) { ChaptersView(player: player) }
        .sheet(isPresented: $diagnostics) { DiagnosticsView(diagnostics: player.diagnostics) }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var diagnostics: PlaybackDiagnostics
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Text("This report contains stage names and numeric codes only. No addresses, titles, account information, credentials or listening positions. It stays in memory and clears at the next selection.").font(.caption)
                Text("BookHarbor 0.3.0 (3)").font(.caption)
                ForEach(diagnostics.events) { Text($0.line).font(.system(.caption, design: .monospaced)) }
                Button("Copy sanitized report") { UIPasteboard.general.string = "BookHarbor 0.3.0 (3)\n" + diagnostics.text }
            }.navigationTitle("Playback diagnostics").toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct BookDetailsView: View {
    let bookID: UUID
    @ObservedObject var library: Library
    @ObservedObject var shelf: ShelfController
    @ObservedObject var downloads: Downloads
    @ObservedObject var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var deleteImport = false
    @State private var detailMessage = ""
    var body: some View {
        NavigationStack {
            List {
                if let book = library.books.first(where: { $0.id == bookID }) {
                    Section {
                        Text(book.title).font(.headline)
                        if let author = book.plex?.author { Text(author) }
                        Text(book.offline ? "Complete local audio available" : book.hasPartialDownload ? "Partial download - connection needed for playback" : "Connection needed for playback")
                        Button("Play or resume") { shelf.play(book); dismiss() }
                        BookMenu(book: book, library: library, shelf: shelf, player: player, downloads: downloads)
                        if book.plex == nil { Button("Delete imported audio", role: .destructive) { deleteImport = true } }
                    }
                    Section("Chapters") {
                        if !detailMessage.isEmpty { Text(detailMessage).font(.caption) }
                        let chapters = book.importedChapters ?? book.tracks.enumerated().flatMap { index, track in BookTimeline.chapters(track.chapters ?? [], track: index, duration: track.duration) }
                        if chapters.isEmpty { Text("Chapter information unavailable.") }
                        ForEach(chapters) { chapter in
                            Button("\(chapter.title) | \(audioClock(chapter.duration))") { shelf.play(book, jump: chapter); dismiss() }
                        }
                    }
                    Section("Files / tracks - not chapter boundaries") {
                        ForEach(Array(book.tracks.enumerated()), id: \.element.id) { index, track in
                            Text("\(index + 1). \(track.title) | \(audioClock(track.duration))")
                        }
                    }
                }
            }.navigationTitle("Book details").toolbar { Button("Done") { dismiss() } }
            .task {
                guard let book = library.books.first(where: { $0.id == bookID }), book.plex != nil, book.tracks.isEmpty else { return }
                detailMessage = "Loading chapter and track metadata…"
                do { _ = try await shelf.plex.resolve(book, library: library); detailMessage = "" }
                catch { detailMessage = (error as? PlexError)?.errorDescription ?? "Track metadata is not available. Retry when connected." }
            }
            .alert("Delete imported audio and its position?", isPresented: $deleteImport) {
                Button("Delete", role: .destructive) {
                    if let book = library.books.first(where: { $0.id == bookID }) { Task { await shelf.removeDownload(book); dismiss() } }
                }
                Button("Cancel", role: .cancel) { }
            }
        }
    }
}

func audioClock(_ value: Double) -> String {
    let seconds = Int(value.isFinite ? max(0, value) : 0)
    return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
}
