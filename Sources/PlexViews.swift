import SwiftUI

struct BookArtwork: View {
    let book: Book
    let root: URL
    var body: some View {
        Group {
            if let file = book.artworkFile, let image = UIImage(contentsOfFile: root.appendingPathComponent(file).path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { Image(systemName: "book.closed.fill").font(.title).foregroundStyle(.teal) }
        }.frame(width: 44, height: 52).clipped().accessibilityHidden(true)
    }
}

struct PlexView: View {
    @ObservedObject var plex: PlexClient
    @ObservedObject var library: Library
    @ObservedObject var player: Player
    @ObservedObject var downloads: Downloads
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var loadingBook = false
    @State private var signingOut = false
    var body: some View {
        NavigationStack {
            List {
                Section("Plex account") {
                    if plex.linked {
                        Button("Discover / refresh servers") { Task { await plex.discover() } }.disabled(plex.busy)
                        Button("Sign out on this iPhone", role: .destructive) {
                            signingOut = true
                            Task {
                                player.stopStreaming()
                                await downloads.signOut()
                                do { try plex.signOut() } catch { plex.status = "Could not remove all credentials. Please retry sign-out." }
                                signingOut = false
                            }
                        }.disabled(signingOut || loadingBook || plex.busy)
                    } else {
                        Button("Link with Plex in browser") { Task { await plex.beginLink() } }.disabled(plex.busy)
                        if let url = plex.browserURL {
                            Button("Open Plex sign-in") { openURL(url) }
                            Button("Cancel linking") { plex.cancelLink() }
                        }
                    }
                    Text(plex.status).font(.caption)
                    Text("Sign in only on Plex’s website. Credentials stay in this iPhone’s Keychain. HTTP-only servers are unsupported; TLS verification stays enabled.").font(.caption)
                }
                if !plex.servers.isEmpty {
                    Section("Authorized servers") {
                        ForEach(plex.servers) { server in
                            Button { Task { await plex.select(server) } } label: {
                                Label(server.name, systemImage: plex.selectedServer == server.id ? "checkmark.circle.fill" : "server.rack")
                            }.disabled(plex.busy || loadingBook)
                        }
                    }
                }
                if !plex.libraries.isEmpty {
                    Section("Audiobook library • music albums") {
                        ForEach(plex.libraries) { section in
                            Button { Task { await plex.selectLibrary(section) } } label: {
                                Label(section.title, systemImage: plex.selectedLibrary == section.id ? "checkmark.circle.fill" : "books.vertical")
                            }.disabled(plex.busy || loadingBook)
                        }
                    }
                }
                if plex.selectedLibrary != nil {
                    Section("Books") {
                        ForEach(plex.albums) { album in
                            VStack(alignment: .leading) {
                                Text(album.title).font(.headline)
                                if let author = album.parentTitle { Text(author).font(.caption) }
                                HStack {
                                    Button("Stream") { load(album, download: false) }
                                    Button("Download") { load(album, download: true) }
                                }.buttonStyle(.bordered).disabled(loadingBook || signingOut)
                            }
                        }
                        if plex.hasMore { Button("Load more books") { Task { await plex.loadMore() } }.disabled(plex.busy) }
                    }
                }
                Section("Storage") {
                    Text("Local audio: \(ByteCountFormatter.string(fromByteCount: library.storageBytes, countStyle: .file))")
                    Text("Long-press a shelf book to download, restart, mark finished, or delete local audio. Plex deletions retain local progress. Partial tracks also count toward storage.").font(.caption)
                    if !downloads.message.isEmpty { Text(downloads.message).font(.caption) }
                }
                Section("About") {
                    Text("BookHarbor 0.2 • Plex preview")
                    Text("No analytics. Local books and progress are excluded from backup. Refresh signing with the same Apple Account and app identifier without uninstalling. Plex progress synchronization and external metadata lookup are not enabled.").font(.caption)
                }
            }
            .navigationTitle("Plex & Settings")
            .toolbar { Button("Done") { dismiss() } }
            .overlay { if loadingBook { ProgressView("Loading book…").padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12)) } }
            .onChange(of: plex.browserURL) { _, url in if let url { openURL(url) } }
        }
    }
    private func load(_ album: PlexMetadata, download: Bool) {
        loadingBook = true
        Task {
            defer { loadingBook = false }
            do {
                let book = try await plex.book(album, library: library)
                // Artwork is optional; audio remains usable when it is absent or fails.
                if let source = book.plex, let key = source.artwork,
                   book.artworkFile == nil, let request = try? plex.request(key, server: source.serverID) {
                    Task { @MainActor in
                        if let (data, _) = try? await PlexTransport.shared.data(request),
                           data.count <= 10 * 1024 * 1024, let image = UIImage(data: data),
                           let jpeg = image.jpegData(compressionQuality: 0.8) {
                            let filename = UUID().uuidString + ".jpg"
                            do {
                                try jpeg.write(to: library.root.appendingPathComponent(filename), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                                library.update(book.id) { $0.artworkFile = filename }
                            } catch { /* Optional artwork. */ }
                        }
                    }
                }
                if download { downloads.start(book) } else { player.open(book); dismiss() }
            } catch { plex.report(error) }
        }
    }
}

struct ChaptersView: View {
    @ObservedObject var player: Player
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Chapters") {
                    if player.chapters.isEmpty { Text("Chapter information unavailable.") }
                    ForEach(player.chapters) { chapter in
                        Button { player.jump(chapter) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(chapter.title)
                                    Text("Track \(chapter.trackIndex + 1) • \(duration(chapter.duration))").font(.caption)
                                }
                                Spacer()
                                if player.currentChapterID == chapter.id { Image(systemName: "speaker.wave.2.fill") }
                            }
                        }
                    }
                }
                if let book = player.book, !book.tracks.isEmpty {
                    Section("Files / tracks • not chapter boundaries") {
                        ForEach(Array(book.tracks.enumerated()), id: \.element.id) { index, track in
                            Button {
                                player.seek(BookTimeline.absolute(track: index, offset: 0, tracks: book.tracks))
                            } label: {
                                HStack {
                                    Text("\(index + 1). \(track.title)")
                                    Spacer(); Text(duration(track.duration)).font(.caption)
                                    if player.trackIndex == index { Image(systemName: "speaker.wave.2.fill") }
                                }
                            }
                        }
                    }
                }
            }.navigationTitle("Chapters & tracks").toolbar { Button("Done") { dismiss() } }
        }
    }
    private func duration(_ seconds: Double) -> String {
        let seconds = Int(max(0, seconds))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
