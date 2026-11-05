import SwiftUI
import UniformTypeIdentifiers

@main struct BookHarborApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var plex: PlexClient
    @StateObject private var downloads: Downloads
    @StateObject private var library: Library
    @StateObject private var player: Player
    @Environment(\.scenePhase) private var phase
    init() {
        let model = Library()
        _library = StateObject(wrappedValue: model)
        let connection = PlexClient()
        let audio = Player(library: model)
        audio.plex = connection
        let transfers = Downloads(library: model, plex: connection)
        _plex = StateObject(wrappedValue: connection)
        _downloads = StateObject(wrappedValue: transfers)
        _player = StateObject(wrappedValue: audio)
        AppDelegate.reconnect = { transfers.reconnect() }
    }
    var body: some Scene {
        WindowGroup {
            ContentView(library: library, player: player, plex: plex, downloads: downloads)
                .onChange(of: phase) { _, phase in
                    player.save()
                    if phase == .background { downloads.pauseForBackground() }
                }
        }
    }
}

struct ContentView: View {
    @ObservedObject var library: Library
    @ObservedObject var player: Player
    @ObservedObject var plex: PlexClient
    @ObservedObject var downloads: Downloads
    @State private var chapterList = false
    @State private var importing = false
    @State private var settings = false
    @State private var pendingDelete: Book?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if library.books.isEmpty {
                    ContentUnavailableView("Your listening shelf", systemImage: "books.vertical", description: Text("Import an audiobook from Files to listen offline. Connect to Plex in Settings to browse your audiobook library."))
                } else {
                    List {
                        let continuing = library.books.filter { $0.position > 0 && $0.finished != true }
                            .sorted { ($0.progress?.updatedAt ?? .distantPast) > ($1.progress?.updatedAt ?? .distantPast) }
                        if !continuing.isEmpty {
                            Section("Continue Listening") { ForEach(continuing) { book in shelfRow(book) } }
                        }
                        Section("All books") { ForEach(library.books) { book in shelfRow(book) } }
                    }
                }
                if let book = player.book {
                    VStack(spacing: 14) {
                        Text(book.title).font(.headline).lineLimit(2)
                        Button("Chapters & tracks") { chapterList = true }
                        Text("\(clock(player.elapsed)) / \(clock(player.duration))")
                            .monospacedDigit().foregroundStyle(.secondary)
                        HStack(spacing: 36) {
                            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                                .accessibilityLabel("Back 15 seconds")
                            Button { player.playing ? player.pause() : player.play() } label: {
                                Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 52))
                            }.accessibilityLabel(player.playing ? "Pause" : "Play")
                            Button { player.skip(30) } label: { Image(systemName: "goforward.30") }
                                .accessibilityLabel("Forward 30 seconds")
                        }.font(.title)
                        HStack {
                            Menu("\(player.speed, specifier: "%.2g")x speed") {
                                ForEach([0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { rate in
                                    Button("\(rate, specifier: "%.2g")x") { player.changeSpeed(Float(rate)) }
                                }
                            }
                            Spacer()
                            Menu(player.sleepMinutes > 0 ? "Sleep: \(player.sleepMinutes) min" : "Sleep timer") {
                                ForEach([0, 15, 30, 45, 60], id: \.self) { minutes in
                                    Button(minutes == 0 ? "Off" : "\(minutes) minutes") { player.setSleep(minutes) }
                                }
                            }
                        }.font(.subheadline)
                    }.padding().background(.thinMaterial)
                }
                if !library.message.isEmpty { Text(library.message).font(.caption).padding() }
                if !player.message.isEmpty { Text(player.message).font(.caption).padding() }
            }
            .navigationTitle("BookHarbor")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Label("Import", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $settings) { PlexView(plex: plex, library: library, player: player, downloads: downloads) }
            .sheet(isPresented: $chapterList) { ChaptersView(player: player) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, UTType(filenameExtension: "m4b") ?? .audio]) { result in
                switch result {
                case .success(let url): library.importFile(url)
                case .failure: library.message = "Import was not completed."
                }
            }
            .alert("Delete downloaded book?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete", role: .destructive) { if let book = pendingDelete { library.remove(book) }; pendingDelete = nil }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { Text("This removes local audio. Plex books retain metadata and progress; imported books and their progress are deleted.") }
        }.tint(.teal)
    }
    @ViewBuilder private func shelfRow(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { player.open(book) } label: {
                HStack {
                    BookArtwork(book: book, root: library.root)
                    VStack(alignment: .leading) {
                        Text(book.title).foregroundStyle(.primary)
                        if let author = book.plex?.author { Text(author).font(.caption) }
                        Text("\(book.offline ? "Offline" : "Plex") | \(book.finished == true ? "Finished" : "Resume at " + clock(book.position))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let job = downloads.jobs.first(where: { $0.bookID == book.id }) {
                Text(job.state).font(.caption)
                ProgressView(value: downloads.fractions[book.id] ?? 0)
                HStack {
                    Button("Retry / resume") { downloads.start(book) }.disabled(job.state == "Downloading")
                    Button("Pause download") { Task { await downloads.cancel(book.id) } }.disabled(job.state != "Downloading")
                    Button("Cancel") { Task { await downloads.cancel(book.id, resumable: false) } }
                }.font(.caption).buttonStyle(.borderless)
            }
        }
        .contextMenu {
            if book.plex != nil && !book.offline { Button("Download offline") { downloads.start(book) } }
            Button(book.finished == true ? "Mark unfinished" : "Mark finished") {
                library.update(book.id) { $0.finished = !(book.finished ?? false) }
            }
            Button("Restart from beginning") {
                if player.book?.id == book.id { player.pause(); player.seek(0) }
                library.update(book.id) { $0.position = 0; $0.progress = nil; $0.finished = false }
            }
            Button("Delete local audio", role: .destructive) { pendingDelete = book }
                .disabled(player.book?.id == book.id || downloads.jobs.contains { $0.bookID == book.id && $0.state == "Downloading" })
        }
    }
    private func clock(_ value: Double) -> String {
        let seconds = Int(value.isFinite ? max(0, value) : 0)
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}
