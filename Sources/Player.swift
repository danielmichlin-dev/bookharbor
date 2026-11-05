import AVFoundation
import MediaPlayer
import Combine

@MainActor final class Player: ObservableObject {
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

    init(library: Library) {
        self.library = library
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
                self.playing = self.engine.rate != 0
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
    func open(_ next: Book, autoplay: Bool = true) {
        pause()
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
        engine.pause(); resource?.cancel(); resource = nil
        openGeneration = UUID(); let generation = openGeneration
        seeking = true; trackIndex = index; trackOffset = offset
        elapsed = BookTimeline.absolute(track: index, offset: offset, tracks: book.tracks)
        let asset: AVURLAsset
        do {
            if let source = book.plex {
                guard source.tracks.indices.contains(index) else { throw PlexError.malformed }
                let track = source.tracks[index]
                if let filename = track.filename {
                    asset = AVURLAsset(url: library.root.appendingPathComponent(filename))
                } else {
                    guard let plex else { throw PlexError.authentication }
                    let loader = MediaResource(request: try plex.mediaRequest(source: source, track: track), bytes: track.bytes, ext: track.ext)
                    resource = loader; asset = loader.asset
                }
            } else { asset = AVURLAsset(url: library.url(for: book)) }
        } catch {
            seeking = false; playing = false
            message = (error as? PlexError)?.errorDescription ?? "Could not open this book."; return
        }
        let item = AVPlayerItem(asset: asset)
        engine.replaceCurrentItem(with: item)
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            if failed { Task { @MainActor in
                self?.message = "This file could not be played. Try a compatible, unprotected audio file."
                self?.pause()
            } }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await self.engine.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard self.openGeneration == generation else { return }
            self.seeking = false
            if ok && self.wantsPlayback { self.play() }
            await self.readChapters(asset, bookID: book.id, track: index, generation: generation)
        }
    }
    func play() {
        guard book != nil else { return }
        wantsPlayback = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            engine.playImmediately(atRate: speed)
            playing = true
            nowPlaying()
        } catch { message = "Could not start audio playback." }
    }
    func pause() {
        wantsPlayback = false
        engine.pause(); playing = false; save(); nowPlaying()
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
            openGeneration = UUID()
            let generation = openGeneration
            engine.seek(to: CMTime(seconds: location.1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.openGeneration == generation else { return }
                    self.seeking = false
                    if wasPlaying && self.wantsPlayback { self.play() }
                }
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
