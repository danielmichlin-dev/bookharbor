import SwiftUI
import UniformTypeIdentifiers

@main struct BookHarborApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var shelf: ShelfController
    @StateObject private var plex: PlexClient
    @StateObject private var downloads: Downloads
    @StateObject private var library: Library
    @StateObject private var player: Player
    @Environment(\.scenePhase) private var phase
    init() {
        let model = Library()
        _library = StateObject(wrappedValue: model)
        let connection = PlexClient(library: model)
        let audio = Player(library: model)
        audio.plex = connection
        let transfers = Downloads(library: model, plex: connection)
        _shelf = StateObject(wrappedValue: ShelfController(library: model, plex: connection, player: audio, downloads: transfers))
        _plex = StateObject(wrappedValue: connection)
        _downloads = StateObject(wrappedValue: transfers)
        _player = StateObject(wrappedValue: audio)
        AppDelegate.reconnect = { transfers.reconnect() }
    }
    var body: some Scene {
        WindowGroup {
            ContentView(library: library, player: player, plex: plex, downloads: downloads, shelf: shelf)
                .onChange(of: phase) { _, phase in
                    player.save()
                    if phase == .background { downloads.pauseForBackground() }
                }
        }
    }
}
