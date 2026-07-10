import Foundation

#if canImport(MediaPlayer)
import MediaPlayer
#endif

public enum AudiobookPlaybackStatus: String, Sendable, Equatable, Hashable, Codable {
    case idle
    case ready
    case playing
    case paused
    case ended
    case failed
}

public struct AudiobookPlaybackSnapshot: Sendable, Equatable {
    public var status: AudiobookPlaybackStatus
    public var position: Position
    public var rate: Float
    public var trackDuration: Double?
    public var totalProgression: Double

    public init(
        status: AudiobookPlaybackStatus,
        position: Position,
        rate: Float,
        trackDuration: Double?,
        totalProgression: Double
    ) {
        self.status = status
        self.position = position
        self.rate = rate
        self.trackDuration = trackDuration
        self.totalProgression = totalProgression
    }
}

public enum AudiobookPlaybackEvent: Sendable, Equatable {
    case ready(AudiobookPlaybackSnapshot)
    case stateChanged(AudiobookPlaybackSnapshot)
    case positionChanged(AudiobookPlaybackSnapshot)
    case trackChanged(index: Int, title: String?)
    case ended
    case error(BookError)
}

@MainActor
public final class AudiobookPlayer {
    public let book: Book
    public var events: AsyncStream<AudiobookPlaybackEvent> {
        eventHub.stream()
    }

    private let timeline: AudiobookTimeline
    private let reader: Reader
    private let resourceStore: AudioResourceStore
    private let engine: any AudiobookPlaybackEngine
    private let eventHub = EventHub<AudiobookPlaybackEvent>()
    private var engineEventTask: Task<Void, Never>?
    private var position: Position = .start
    private var status: AudiobookPlaybackStatus = .idle
    private var playbackRate: Float = 1
    private var isPrepared = false
    private var lastPersistedTimestamp: Double?
    #if canImport(MediaPlayer)
    private var remoteCommandTargets: [(command: MPRemoteCommand, token: Any)] = []
    #endif

    public init(
        book: Book,
        options: OpenOptions = OpenOptions(),
        stateStore: (any ReaderStateStore)? = nil,
        engine: (any AudiobookPlaybackEngine)? = nil
    ) throws {
        timeline = try AudiobookTimeline(book: book)
        self.book = book
        reader = Reader(book: book, stateStore: stateStore)
        resourceStore = AudioResourceStore(book: book, options: options)
        if let engine {
            self.engine = engine
        } else {
            #if canImport(AVFoundation)
            self.engine = AVFoundationAudiobookEngine()
            #else
            throw BookError.renderingFailed("AVFoundation is unavailable on this platform")
            #endif
        }
        startEngineEvents()
    }

    deinit {
        engineEventTask?.cancel()
    }

    public func prepare() async throws {
        guard !isPrepared else { return }
        try await reader.restore()
        let restored = await reader.position
        position = normalized(restored)
        try await loadTrack(at: position, shouldResumePlayback: false)
        isPrepared = true
        status = .ready
        let snapshot = snapshot()
        eventHub.yield(.ready(snapshot))
        updateNowPlaying(snapshot)
    }

    public func play() async throws {
        try await prepare()
        engine.play(rate: playbackRate)
        status = .playing
        emitStateChanged()
    }

    public func pause() async throws {
        engine.pause()
        status = .paused
        try await persistCurrentPosition()
        emitStateChanged()
    }

    public func seek(to target: Position) async throws {
        try await prepare()
        let destination = normalized(target)
        let changesTrack = destination.spineIndex != position.spineIndex
        let wasPlaying = engine.isPlaying
        position = destination
        if changesTrack {
            try await loadTrack(at: destination, shouldResumePlayback: wasPlaying)
        } else {
            engine.seek(to: destination.timestamp ?? 0)
        }
        try await reader.go(to: destination)
        lastPersistedTimestamp = destination.timestamp
        emitPositionChanged()
    }

    public func seek(toTimestamp timestamp: Double) async throws {
        try await seek(to: timeline.position(trackIndex: position.spineIndex, timestamp: timestamp))
    }

    public func nextTrack() async throws -> Bool {
        try await prepare()
        guard let next = timeline.nextTrack(from: position) else { return false }
        try await seek(to: next)
        return true
    }

    public func previousTrack(restartsAfter seconds: Double = 5) async throws -> Bool {
        try await prepare()
        let start = timeline.startPosition(ofTrackAt: position.spineIndex)
        if (position.timestamp ?? 0) - (start.timestamp ?? 0) > max(seconds, 0) {
            try await seek(to: start)
            return true
        }
        guard let previous = timeline.previousTrack(from: position) else {
            try await seek(to: start)
            return false
        }
        try await seek(to: previous)
        return true
    }

    public func setRate(_ rate: Float) {
        playbackRate = min(max(rate, 0.5), 3)
        if engine.isPlaying {
            engine.play(rate: playbackRate)
        }
        emitStateChanged()
    }

    public func currentSnapshot() -> AudiobookPlaybackSnapshot {
        snapshot()
    }

    public func currentPosition() -> Position {
        position
    }

    public func addBookmark(note: String? = nil) async throws -> ReadingBookmark {
        await reader.sync(to: position)
        return try await reader.addBookmark(note: note)
    }

    public func bookmarks() async -> [ReadingBookmark] {
        await reader.bookmarksList()
    }

    public func updateBookmark(id: UUID, note: String?) async throws {
        try await reader.updateBookmark(id: id, note: note)
    }

    public func removeBookmark(id: UUID) async throws {
        try await reader.removeBookmark(id: id)
    }

    public func activateRemoteCommands(skipInterval: Double = 15) {
        #if canImport(MediaPlayer)
        deactivateRemoteCommands()
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: max(skipInterval, 1))]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: max(skipInterval, 1))]

        addTarget(to: center.playCommand) { [weak self] _ in
            Task { @MainActor [weak self] in try? await self?.play() }
            return .success
        }
        addTarget(to: center.pauseCommand) { [weak self] _ in
            Task { @MainActor [weak self] in try? await self?.pause() }
            return .success
        }
        addTarget(to: center.nextTrackCommand) { [weak self] _ in
            Task { @MainActor [weak self] in _ = try? await self?.nextTrack() }
            return .success
        }
        addTarget(to: center.previousTrackCommand) { [weak self] _ in
            Task { @MainActor [weak self] in _ = try? await self?.previousTrack() }
            return .success
        }
        addTarget(to: center.skipForwardCommand) { [weak self] event in
            guard let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.seek(
                    toTimestamp: (self.currentPosition().timestamp ?? 0) + event.interval
                )
            }
            return .success
        }
        addTarget(to: center.skipBackwardCommand) { [weak self] event in
            guard let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.seek(
                    toTimestamp: (self.currentPosition().timestamp ?? 0) - event.interval
                )
            }
            return .success
        }
        addTarget(to: center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in
                try? await self?.seek(toTimestamp: event.positionTime)
            }
            return .success
        }
        #endif
    }

    public func deactivateRemoteCommands() {
        #if canImport(MediaPlayer)
        for target in remoteCommandTargets {
            target.command.removeTarget(target.token)
        }
        remoteCommandTargets.removeAll()
        #endif
    }

    public func shutdown(removesTemporaryAudio: Bool = true) async {
        engine.pause()
        try? await persistCurrentPosition()
        engine.shutdown()
        engineEventTask?.cancel()
        engineEventTask = nil
        if removesTemporaryAudio {
            try? await resourceStore.removeAll()
        }
        deactivateRemoteCommands()
        clearNowPlaying()
    }

    private func startEngineEvents() {
        let stream = engine.events
        engineEventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handleEngineEvent(event)
            }
        }
    }

    private func handleEngineEvent(_ event: AudiobookEngineEvent) async {
        switch event {
        case .ready:
            break
        case let .timeChanged(timestamp):
            position = timeline.position(trackIndex: position.spineIndex, timestamp: timestamp)
            await reader.sync(to: position)
            if shouldPersist(timestamp: timestamp) {
                try? await reader.go(to: position)
                lastPersistedTimestamp = timestamp
            }
            emitPositionChanged()
        case let .playingChanged(isPlaying):
            status = isPlaying ? .playing : (isPrepared ? .paused : .idle)
            emitStateChanged()
        case .ended:
            if let next = timeline.nextTrack(from: position) {
                let shouldPlay = status == .playing
                position = next
                do {
                    try await loadTrack(at: next, shouldResumePlayback: shouldPlay)
                    try await reader.go(to: next)
                } catch {
                    report(error)
                }
            } else {
                status = .ended
                try? await persistCurrentPosition()
                eventHub.yield(.ended)
                emitStateChanged()
            }
        case let .failed(error):
            report(error)
        }
    }

    private func loadTrack(at target: Position, shouldResumePlayback: Bool) async throws {
        let index = target.spineIndex
        let url = try await resourceStore.url(forTrackAt: index)
        let chapter = book.readingOrder[index]
        try await engine.load(
            url: url,
            clipBegin: chapter.audio?.clipBegin ?? 0,
            clipEnd: chapter.audio?.clipEnd
        )
        engine.seek(to: target.timestamp ?? chapter.audio?.clipBegin ?? 0)
        if shouldResumePlayback {
            engine.play(rate: playbackRate)
            status = .playing
        }
        eventHub.yield(.trackChanged(index: index, title: chapter.title))
        updateNowPlaying(snapshot())
    }

    private func normalized(_ value: Position) -> Position {
        guard !book.readingOrder.isEmpty else { return .start }
        let index = min(max(value.spineIndex, 0), book.readingOrder.count - 1)
        let chapter = book.readingOrder[index]
        let begin = chapter.audio?.clipBegin ?? 0
        let duration = timeline.duration(ofTrackAt: index)
        let timestamp = value.timestamp ?? begin + value.progression * duration
        return timeline.position(trackIndex: index, timestamp: timestamp)
    }

    private func snapshot() -> AudiobookPlaybackSnapshot {
        AudiobookPlaybackSnapshot(
            status: status,
            position: position,
            rate: playbackRate,
            trackDuration: timeline.duration(ofTrackAt: position.spineIndex),
            totalProgression: timeline.globalProgression(for: position)
        )
    }

    private func shouldPersist(timestamp: Double) -> Bool {
        guard let lastPersistedTimestamp else { return true }
        return abs(timestamp - lastPersistedTimestamp) >= 5
    }

    private func persistCurrentPosition() async throws {
        try await reader.go(to: position)
        lastPersistedTimestamp = position.timestamp
    }

    private func emitStateChanged() {
        let snapshot = snapshot()
        eventHub.yield(.stateChanged(snapshot))
        updateNowPlaying(snapshot)
    }

    private func emitPositionChanged() {
        let snapshot = snapshot()
        eventHub.yield(.positionChanged(snapshot))
        updateNowPlaying(snapshot)
    }

    private func report(_ error: Error) {
        let bookError = BookError.from(error)
        status = .failed
        eventHub.yield(.error(bookError))
        emitStateChanged()
    }

    private func updateNowPlaying(_ snapshot: AudiobookPlaybackSnapshot) {
        #if canImport(MediaPlayer)
        let clipBegin = book.readingOrder.indices.contains(snapshot.position.spineIndex)
            ? book.readingOrder[snapshot.position.spineIndex].audio?.clipBegin ?? 0
            : 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: book.readingOrder.indices.contains(snapshot.position.spineIndex)
                ? book.readingOrder[snapshot.position.spineIndex].title ?? book.metadata.title
                : book.metadata.title,
            MPMediaItemPropertyAlbumTitle: book.metadata.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(
                (snapshot.position.timestamp ?? clipBegin) - clipBegin,
                0
            ),
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.status == .playing ? snapshot.rate : 0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: snapshot.position.spineIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: book.readingOrder.count,
        ]
        if let author = book.metadata.authors.first {
            info[MPMediaItemPropertyArtist] = author
        }
        if let duration = snapshot.trackDuration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    #if canImport(MediaPlayer)
    private func addTarget(
        to command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let token = command.addTarget(handler: handler)
        remoteCommandTargets.append((command, token))
    }
    #endif

    private func clearNowPlaying() {
        #if canImport(MediaPlayer)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }
}
