import AVFoundation
import MediaPlayer
import Combine

@MainActor final class Player: ObservableObject {
    @Published var state: PlaybackState = .idle
    let diagnostics = PlaybackDiagnostics()
    private var preparation = PlaybackPreparation(offset: 0)
    private var preparationTimeout: Task<Void, Never>?
    private var timeControlObserver: NSKeyValueObservation?
    private var seekToken = UUID()
    private let remoteRequest: ((PlexBookSource, BookTrack) throws -> URLRequest)?
    private let fetch: MediaResource.Fetch?
    @Published var book: Book?
    @Published var playing = false
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
    @Published var speed: Float = 1
    @Published var message = ""
    @Published var sleepMinutes = 0
    @Published var chapters: [BookChapter] = []
    @Published var trackIndex = 0
    private var resource: MediaResource?
    private var openGeneration = UUID()
    private var seeking = false
    private var wantsPlayback = false
    private var trackOffset: Double = 0
    var plex: PlexClient?
    private let engine = AVPlayer()
    private var observer: Any?
    private var statusObserver: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var sleepTask: Task<Void, Never>?
    private var ticks = 0
    let library: Library

    init(library: Library, remoteRequest: ((PlexBookSource, BookTrack) throws -> URLRequest)? = nil,
         fetch: MediaResource.Fetch? = nil) {
        self.library = library; self.remoteRequest = remoteRequest; self.fetch = fetch
        timeControlObserver = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updatePlaybackState() }
        }
        observer = engine.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                guard !self.seeking else { return }
                let current = self.engine.currentTime().seconds
                guard self.engine.currentItem?.status == .readyToPlay else { return }
                self.trackOffset = current.isFinite ? current : 0
                self.elapsed = BookTimeline.absolute(track: self.trackIndex, offset: self.trackOffset, tracks: self.book?.tracks ?? [])
                let length = self.engine.currentItem?.duration.seconds ?? 0
                self.duration = self.book?.plex != nil ? (self.book?.tracks.reduce(0) { $0 + $1.duration } ?? 0) : (length.isFinite ? length : 0)
                self.updatePlaybackState()
                self.ticks += 1
                if self.ticks % 5 == 0 { self.save() }
                self.nowPlaying()
            }
        }
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }; return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }; return .success
        }
        commands.skipForwardCommand.preferredIntervals = [30]
        commands.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(30) }; return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(-15) }; return .success
        }
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if type == AVAudioSession.InterruptionType.began.rawValue {
                Task { @MainActor in self?.pause() }
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, item === self.engine.currentItem else { return }
                if let book = self.book, self.trackIndex + 1 < book.tracks.count {
                    self.save(); self.loadTrack(self.trackIndex + 1, offset: 0, autoplay: true)
                } else { self.pause() }
            }
        })
    }
    func prepareSelection() {
        close(); diagnostics.clear(); message = ""; state = .loading
        diagnostics.record(.selection, .started)
    }
    func failSelection(_ error: Error) { fail((error as? PlexError) ?? .unavailable) }
    func open(_ next: Book, autoplay: Bool = true, resetDiagnostics: Bool = true) {
        pause()
        if resetDiagnostics { diagnostics.clear(); diagnostics.record(.selection, .started) }
        let latest = library.books.first(where: { $0.id == next.id }) ?? next
        book = latest
        elapsed = latest.position
        duration = 0
        message = ""
        chapters = latest.importedChapters ?? latest.tracks.enumerated().flatMap { index, track in
            BookTimeline.chapters(track.chapters ?? [], track: index, duration: track.duration)
        }
        let location = BookTimeline.location(latest.position, tracks: latest.tracks)
        // Prefer the explicit file/offset checkpoint; total seconds remains for v0.1 imports.
        let checkpoint = latest.progress
        let index = checkpoint?.trackID.flatMap { id in latest.tracks.firstIndex(where: { $0.id == id }) } ?? location.0
        loadTrack(index, offset: checkpoint?.offset ?? location.1, autoplay: autoplay)
    }
    private func loadTrack(_ index: Int, offset: Double, autoplay: Bool) {
        guard let currentBook = book else { return }
        let book = library.books.first(where: { $0.id == currentBook.id }) ?? currentBook
        self.book = book
        wantsPlayback = autoplay
        engine.pause(); engine.replaceCurrentItem(with: nil); resource?.cancel(); resource = nil
        openGeneration = UUID(); let generation = openGeneration
        preparationTimeout?.cancel()
        preparation = PlaybackPreparation(offset: offset)
        state = .loading; playing = false
        seeking = true; trackIndex = index; trackOffset = offset
        elapsed = BookTimeline.absolute(track: index, offset: offset, tracks: book.tracks)
        let asset: AVURLAsset
        do {
            if let source = book.plex {
                guard source.tracks.indices.contains(index) else { throw PlexError.malformed }
                let track = source.tracks[index]
                if Bookshelf.source(for: book) == .downloaded, let filename = track.filename,
                   FileManager.default.fileExists(atPath: library.root.appendingPathComponent(filename).path) {
                    diagnostics.record(.source, .local)
                    asset = AVURLAsset(url: library.root.appendingPathComponent(filename))
                } else {
                    diagnostics.record(.connection, .started)
                    let request: URLRequest
                    if let remoteRequest { request = try remoteRequest(source, track) }
                    else {
                        guard let plex else { throw PlexError.authentication }
                        request = try plex.mediaRequest(source: source, track: track)
                    }
                    diagnostics.record(.authentication, .started)
                    let loader = MediaResource(request: request, bytes: track.bytes, ext: track.ext,
                        fetch: fetch ?? { try await PlexTransport.shared.data($0, limit: $1) })
                    loader.event = { [weak self] stage, fact, code in
                        guard let self, self.openGeneration == generation else { return }
                        self.diagnostics.record(stage, fact, code: code)
                        if stage == .http && code == 206 { self.diagnostics.record(.authentication, .ready) }
                    }
                    loader.failure = { [weak self] error in
                        guard let self, self.openGeneration == generation else { return }
                        self.fail(error)
                    }
                    diagnostics.record(.source, .streaming)
                    resource = loader; asset = loader.asset
                }
            } else {
                diagnostics.record(.source, .local)
                asset = AVURLAsset(url: library.url(for: book))
            }
        } catch { fail((error as? PlexError) ?? .unavailable); return }

        diagnostics.record(.item, .started)
        let item = AVPlayerItem(asset: asset)
        engine.replaceCurrentItem(with: item)
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.openGeneration == generation, self.engine.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    guard let offset = self.preparation.becameReady() else { return }
                    self.diagnostics.record(.readiness, .ready)
                    self.restore(offset, generation: generation)
                    Task { await self.readChapters(asset, bookID: book.id, track: index, generation: generation) }
                case .failed:
                    self.diagnostics.recordErrorCodes(item.error, stage: .item)
                    if self.state != .failed { self.fail(.unsupported) }
                default: break
                }
            }
        }
        diagnostics.record(.readiness, .waiting)
        preparationTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 40_000_000_000) } catch { return }
            guard let self, self.openGeneration == generation, self.seeking else { return }
            self.diagnostics.record(self.preparation.ready ? .seek : .readiness, .timeout)
            self.fail(.preparation)
        }
    }
    private func restore(_ offset: Double, generation: UUID) {
        // Avoid the unnecessary seek-to-zero altogether. A resume seek is issued
        // only after readyToPlay, and its failure cannot silently disable autoplay.
        if offset == 0 { finishRestore(generation: generation); return }
        diagnostics.record(.seek, .started)
        seekToken = UUID(); let token = seekToken
        engine.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.openGeneration == generation, self.seekToken == token else { return }
                guard finished else { self.diagnostics.record(.seek, .interrupted); self.fail(.seekFailed); return }
                self.diagnostics.record(.seek, .complete)
                self.finishRestore(generation: generation)
            }
        }
    }
    private func finishRestore(generation: UUID) {
        guard openGeneration == generation, state != .failed else { return }
        preparationTimeout?.cancel(); seeking = false
        if wantsPlayback { play() } else { state = .paused }
    }
    private func updatePlaybackState() {
        guard book != nil, state != .failed, !seeking else { return }
        switch engine.timeControlStatus {
        case .playing:
            if state != .playing { diagnostics.record(.playing, .started) }
            state = .playing; playing = true
        case .waitingToPlayAtSpecifiedRate:
            if state != .buffering { diagnostics.record(.buffering, .waiting) }
            state = wantsPlayback ? .buffering : .paused; playing = false
        default:
            state = wantsPlayback ? .buffering : .paused; playing = false
        }
    }
    private func fail(_ error: PlexError) {
        preparationTimeout?.cancel(); wantsPlayback = false
        engine.pause(); playing = false; state = .failed
        switch error {
        case .http(let code): diagnostics.record(.http, .rejected, code: code)
        case .network(let code): diagnostics.record(.connection, .failed, code: code)
        case .authentication: diagnostics.record(.authentication, .rejected)
        case .unsafeURL: diagnostics.record(.connection, .rejected)
        default: break
        }
        diagnostics.record(.failure, .failed)
        message = error.errorDescription ?? "Playback failed."
        // Do not sample an unready item's zero time over the stored checkpoint.
    }
    func play() {
        guard book != nil else { return }
        wantsPlayback = true
        guard preparation.ready, !seeking, state != .failed else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            diagnostics.record(.audioSession, .ready)
            engine.playImmediately(atRate: speed)
            updatePlaybackState(); nowPlaying()
        } catch {
            diagnostics.record(.audioSession, .failed, code: (error as NSError).code)
            fail(.unavailable)
        }
    }
    func pause() {
        wantsPlayback = false
        engine.pause(); playing = false; save(); nowPlaying()
        if state != .failed {
            if state != .paused { diagnostics.record(.paused, .complete) }
            state = .paused
        }
    }
    func skip(_ seconds: Double) {
        let target = max(0, min(elapsed + seconds, duration > 0 ? duration : .greatestFiniteMagnitude))
        seek(target)
    }
    func changeSpeed(_ value: Float) { speed = value; if playing { engine.rate = value }; nowPlaying() }
    func save() {
        if let book {
            if !seeking, engine.currentItem?.status == .readyToPlay {
                let time = engine.currentTime().seconds
                if time.isFinite {
                    trackOffset = max(0, time)
                    elapsed = BookTimeline.absolute(track: trackIndex, offset: trackOffset, tracks: book.tracks)
                }
            }
            let chapter = chapters.last(where: { $0.trackIndex == trackIndex && trackOffset >= $0.start && trackOffset < $0.end })
            library.record(book.id, position: elapsed, track: trackIndex, offset: trackOffset, chapter: chapter?.id)
        }
    }
    func seek(_ target: Double) {
        guard let book else { return }
        let wasPlaying = wantsPlayback
        let location = BookTimeline.location(max(0, target), tracks: book.tracks)
        if location.0 != trackIndex {
            loadTrack(location.0, offset: location.1, autoplay: wasPlaying)
            save()
        } else {
            seeking = true; elapsed = target; trackOffset = location.1; save()
            if let offset = preparation.requestSeek(location.1) {
                state = .loading
                restore(offset, generation: openGeneration)
            }
        }
        nowPlaying()
    }
    func jump(_ chapter: BookChapter) {
        seek(BookTimeline.absolute(track: chapter.trackIndex, offset: chapter.start, tracks: book?.tracks ?? []))
    }
    var currentChapterID: String? {
        chapters.last(where: { $0.trackIndex == trackIndex && trackOffset >= $0.start && trackOffset < $0.end })?.id
    }
    func stopStreaming() {
        if book?.plex != nil && resource != nil {
            pause(); openGeneration = UUID(); resource?.cancel(); resource = nil
            engine.replaceCurrentItem(with: nil); book = nil
        }
    }
    func close() {
        pause(); openGeneration = UUID(); preparationTimeout?.cancel()
        resource?.cancel(); resource = nil; engine.replaceCurrentItem(with: nil)
        book = nil; state = .idle; MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    private func readChapters(_ asset: AVURLAsset, bookID: UUID, track: Int, generation: UUID) async {
        do {
            let found = try await ChapterReader.read(asset, track: track)
            guard generation == openGeneration, !found.isEmpty else { return }
            chapters.removeAll { $0.trackIndex == track }; chapters += found
            chapters.sort { $0.trackIndex == $1.trackIndex ? $0.start < $1.start : $0.trackIndex < $1.trackIndex }
            let cache = chapters
            library.update(bookID) { $0.importedChapters = cache }
        } catch { /* Chapter absence or unsupported metadata never blocks audio. */ }
    }
    func setSleep(_ minutes: Int) {
        sleepTask?.cancel(); sleepMinutes = minutes
        guard minutes > 0 else { return }
        sleepTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000) }
            catch { return }
            self?.pause(); self?.sleepMinutes = 0
        }
    }
    private func nowPlaying() {
        guard let book else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: book.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : 0
        ]
    }
}
