import SwiftUI
import UniformTypeIdentifiers

@main struct BookHarborApp: App {
    @StateObject private var library: Library
    @StateObject private var player: Player
    @Environment(\.scenePhase) private var phase
    init() {
        let model = Library()
        _library = StateObject(wrappedValue: model)
        _player = StateObject(wrappedValue: Player(library: model))
    }
    var body: some Scene {
        WindowGroup {
            ContentView(library: library, player: player)
                .onChange(of: phase) { _, _ in player.save() }
        }
    }
}

struct ContentView: View {
    @ObservedObject var library: Library
    @ObservedObject var player: Player
    @State private var importing = false
    @State private var settings = false
    @State private var pendingDelete: Book?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if library.books.isEmpty {
                    ContentUnavailableView("Your listening shelf", systemImage: "books.vertical", description: Text("Import an audiobook from Files to listen offline. Plex connection is coming in the next milestone."))
                } else {
                    List(library.books) { book in
                        Button { player.open(book) } label: {
                            HStack {
                                Image(systemName: "book.closed.fill").font(.title).foregroundStyle(.teal)
                                VStack(alignment: .leading) {
                                    Text(book.title).foregroundStyle(.primary)
                                    Text("Offline • Resume at \(clock(book.position))").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 6)
                        }.swipeActions {
                            Button("Delete", role: .destructive) { pendingDelete = book }
                                .disabled(player.book?.id == book.id)
                        }
                    }
                }
                if let book = player.book {
                    VStack(spacing: 14) {
                        Text(book.title).font(.headline).lineLimit(2)
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
                            Menu("\(player.speed, specifier: "%.2g")× speed") {
                                ForEach([0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { rate in
                                    Button("\(rate, specifier: "%.2g")×") { player.changeSpeed(Float(rate)) }
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
            .sheet(isPresented: $settings) { SettingsView() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, UTType(filenameExtension: "m4b") ?? .audio]) { result in
                switch result {
                case .success(let url): library.importFile(url)
                case .failure: library.message = "Import was not completed."
                }
            }
            .alert("Delete downloaded book?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete", role: .destructive) { if let book = pendingDelete { library.remove(book) }; pendingDelete = nil }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { Text("This removes the local copy and its saved position.") }
        }.tint(.teal)
    }
    private func clock(_ value: Double) -> String {
        let seconds = Int(value.isFinite ? max(0, value) : 0)
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var server = SecureSettings.read("server")
    @State private var token = SecureSettings.read("token")
    @State private var status = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Plex setup • next milestone") {
                    Text("These settings are stored privately on this iPhone. This starter does not yet connect to Plex.")
                    TextField("HTTPS server address", text: $server).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("Plex token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save on this iPhone") {
                        guard server.isEmpty || validServer(server) else { status = "Enter an HTTPS server address without a username, password, query, or fragment."; return }
                        do {
                            try SecureSettings.write(server, key: "server")
                            try SecureSettings.write(token, key: "token")
                            status = "Saved in this iPhone’s Keychain."
                        } catch { status = "Settings could not be fully saved. Please retry." }
                    }
                    Button("Clear saved connection", role: .destructive) {
                        do {
                            try SecureSettings.write("", key: "server")
                            try SecureSettings.write("", key: "token")
                            server = ""; token = ""; status = "Connection settings cleared."
                        } catch { status = "Could not clear all settings. Please retry." }
                    }
                    if !status.isEmpty { Text(status).font(.caption) }
                }
                Section("About this starter") {
                    Text("Version 0.1 • Offline playback prototype")
                    Text("No analytics, advertising, or network requests. Books and progress are stored locally and excluded from device backup. Do not uninstall the app to refresh signing: uninstalling removes local books and progress.")
                    Text("Free sideloaded installations need their signing refreshed every seven days. An expired app cannot open, including for offline listening.")
                }
            }.navigationTitle("Settings")
                .toolbar { Button("Done") { dismiss() } }
        }
    }
    private func validServer(_ text: String) -> Bool {
        guard let url = URLComponents(string: text), url.scheme == "https", let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }
}
