import Foundation

public enum AudiobookEngineEvent: Sendable, Equatable {
    case ready(duration: Double?)
    case timeChanged(Double)
    case playingChanged(Bool)
    case ended
    case failed(BookError)
}

@MainActor
public protocol AudiobookPlaybackEngine: AnyObject {
    var events: AsyncStream<AudiobookEngineEvent> { get }
    var duration: Double? { get }
    var isPlaying: Bool { get }
    var rate: Float { get }

    func load(url: URL, clipBegin: Double, clipEnd: Double?) async throws
    func play(rate: Float)
    func pause()
    func seek(to timestamp: Double)
    func shutdown()
}

public extension AudiobookPlaybackEngine {
    func shutdown() {}
}

#if canImport(AVFoundation)
import AVFoundation

@MainActor
public final class AVFoundationAudiobookEngine: AudiobookPlaybackEngine {
    public var events: AsyncStream<AudiobookEngineEvent> {
        eventHub.stream()
    }
    public private(set) var duration: Double?
    public var isPlaying: Bool { player.rate != 0 }
    public var rate: Float { player.rate }

    private let player = AVPlayer()
    private let eventHub = EventHub<AudiobookEngineEvent>()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var clipBegin: Double = 0
    private var clipEnd: Double?
    private var desiredRate: Float = 1

    public init() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.handleTime(CMTimeGetSeconds(time))
            }
        }
    }

    isolated deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    public func load(url: URL, clipBegin: Double, clipEnd: Double?) async throws {
        pause()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        let asset = AVURLAsset(url: url)
        #if os(visionOS)
        guard url.isFileURL else {
            throw BookError.protectedContent(
                ContentProtection(
                    kind: .audioDRM,
                    scheme: "remote audio protection cannot be verified on visionOS",
                    resource: url.absoluteString
                )
            )
        }
        try AudioProtectionProbe.validateFile(at: url)
        #else
        let hasProtectedContent: Bool
        do {
            hasProtectedContent = try await asset.load(.hasProtectedContent)
        } catch {
            throw BookError.renderingFailed("Unable to inspect audio protection: \(error)")
        }
        guard !hasProtectedContent else {
            throw BookError.protectedContent(
                ContentProtection(
                    kind: .audioDRM,
                    scheme: "AVFoundation protected content",
                    resource: url.lastPathComponent
                )
            )
        }
        #endif

        let playable: Bool
        do {
            playable = try await asset.load(.isPlayable)
        } catch {
            throw BookError.renderingFailed("Unable to inspect audio asset: \(error)")
        }
        guard playable else {
            throw BookError.renderingFailed("Audio resource is not playable")
        }

        let assetDuration = try? await asset.load(.duration)
        let seconds = assetDuration.map(CMTimeGetSeconds).flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        }
        self.clipBegin = max(clipBegin, 0)
        self.clipEnd = clipEnd.map { max($0, self.clipBegin) }
        if let clipEnd = self.clipEnd {
            duration = clipEnd - self.clipBegin
        } else if let seconds {
            duration = max(seconds - self.clipBegin, 0)
        } else {
            duration = nil
        }

        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.eventHub.yield(.ended)
            }
        }
        seek(to: self.clipBegin)
        eventHub.yield(.ready(duration: duration))
    }

    public func play(rate: Float = 1) {
        desiredRate = min(max(rate, 0.5), 3)
        player.playImmediately(atRate: desiredRate)
        eventHub.yield(.playingChanged(true))
    }

    public func pause() {
        player.pause()
        eventHub.yield(.playingChanged(false))
    }

    public func seek(to timestamp: Double) {
        let upper = clipEnd ?? timestamp
        let clamped = min(max(timestamp, clipBegin), max(upper, clipBegin))
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    public func shutdown() {
        pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func handleTime(_ seconds: Double) {
        guard seconds.isFinite else { return }
        if let clipEnd, seconds >= clipEnd - 0.01 {
            pause()
            seek(to: clipEnd)
            eventHub.yield(.timeChanged(clipEnd))
            eventHub.yield(.ended)
            return
        }
        eventHub.yield(.timeChanged(max(seconds, clipBegin)))
    }
}
#endif
