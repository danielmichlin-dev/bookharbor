import SwiftUI

struct PlexView: View {
    @ObservedObject var plex: PlexClient
    @ObservedObject var library: Library
    @ObservedObject var player: Player
    @ObservedObject var downloads: Downloads
    @ObservedObject var shelf: ShelfController
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
                                shelf.cancelSelection()
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
                    Text("Sign in only on Plexâ€™s website. Credentials stay in this iPhoneâ€™s Keychain. HTTP-only servers are unsupported; TLS verification stays enabled.").font(.caption)
                }
                if !plex.servers.isEmpty {
                    Section("Authorized servers") {
                        ForEach(plex.servers) { server in
                            Button { Task { await plex.select(server) } } label: {
                                Label(server.name, systemImage: plex.selectedServer == server.id ? "checkmark.circle.fill" : "server.rack")
                            }.disabled(plex.busy)
                        }
                    }
                }
                if !plex.libraries.isEmpty {
                    Section("Audiobook library â€¢ music albums") {
                        ForEach(plex.libraries) { section in
                            Button { Task { await plex.selectLibrary(section) } } label: {
                                Label(section.title, systemImage: plex.selectedLibrary == section.id ? "checkmark.circle.fill" : "books.vertical")
                            }.disabled(plex.busy)
                        }
                    }
                }
                Section("Storage") {
                    Text("Keep BookHarbor open while downloading. Transfers pause when the app enters the background. iOS background downloads cannot enforce this appâ€™s redirect policy; unattended background transfers are deferred.").font(.caption)
                    Text("Local audio: \(ByteCountFormatter.string(fromByteCount: library.storageBytes, countStyle: .file))")
                    Text("Long-press a shelf book to download, restart, mark finished, or delete local audio. Plex deletions retain local progress. Partial tracks also count toward storage.").font(.caption)
                    if !downloads.message.isEmpty { Text(downloads.message).font(.caption) }
                }
                Section("About") {
                    Text("BookHarbor 0.3 â€¢ Plex preview")
                    Text("No analytics. Local books and progress are excluded from backup. Refresh signing with the same Apple Account and app identifier without uninstalling. Plex progress synchronization and external metadata lookup are not enabled.").font(.caption)
                }
            }
            .navigationTitle("Plex & Settings")
            .toolbar { Button("Done") { dismiss() } }
            .overlay { if loadingBook { ProgressView("Loading bookâ€¦").padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12)) } }
            .onChange(of: library.selection) { _, _ in dismiss() }
            .onChange(of: plex.browserURL) { _, url in if let url { openURL(url) } }
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
                                    Text("Track \(chapter.trackIndex + 1) â€¢ \(duration(chapter.duration))").font(.caption)
                                }
                                Spacer()
                                if player.currentChapterID == chapter.id { Image(systemName: "speaker.wave.2.fill") }
                            }
                        }
                    }
                }
                if let book = player.book, !book.tracks.isEmpty {
                    Section("Files / tracks â€¢ not chapter boundaries") {
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
