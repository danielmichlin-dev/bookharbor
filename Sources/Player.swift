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
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                let length = self.engine.currentItem?.duration.seconds ?? 0
                self.duration = length.isFinite ? length : 0
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
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        })
    }
    func open(_ next: Book) {
        pause()
        book = next
        elapsed = next.position
        duration = 0
        message = ""
        let item = AVPlayerItem(url: library.url(for: next))
        engine.replaceCurrentItem(with: item)
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            if failed { Task { @MainActor in
                self?.message = "This file could not be played. Try a compatible, unprotected audio file."
                self?.pause()
            } }
        }
        engine.seek(to: CMTime(seconds: next.position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        play()
    }
    func play() {
        guard book != nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            engine.playImmediately(atRate: speed)
            playing = true
            nowPlaying()
        } catch { message = "Could not start audio playback." }
    }
    func pause() {
        engine.pause(); playing = false; save(); nowPlaying()
    }
    func skip(_ seconds: Double) {
        let target = max(0, min(elapsed + seconds, duration > 0 ? duration : .greatestFiniteMagnitude))
        engine.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = target; save(); nowPlaying()
    }
    func changeSpeed(_ value: Float) { speed = value; if playing { engine.rate = value }; nowPlaying() }
    func save() { if let book { library.record(book.id, position: elapsed) } }
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
