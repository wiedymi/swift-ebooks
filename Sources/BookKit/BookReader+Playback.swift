import Foundation

/// Audiobook playback controls.
public extension BookReader {
    /// Starts or resumes audiobook playback.
    func play() async throws {
        let player = try requirePlayer()
        try await player.play()
        applyPlayback(player.currentSnapshot())
    }

    /// Pauses audiobook playback.
    func pause() async throws {
        let player = try requirePlayer()
        try await player.pause()
        applyPlayback(player.currentSnapshot())
    }

    /// Seeks within the current audiobook track.
    ///
    /// - Parameter timestamp: The absolute track timestamp in seconds.
    func seek(toTimestamp timestamp: Double) async throws {
        let player = try requirePlayer()
        try await player.seek(toTimestamp: timestamp)
        try await renderer.go(to: player.currentPosition())
        await refreshState()
    }

    /// Moves forward or backward by a number of seconds.
    func skip(by seconds: Double) async throws {
        let player = try requirePlayer()
        try await seek(toTimestamp: (player.currentPosition().timestamp ?? 0) + seconds)
    }

    /// Changes audiobook playback speed.
    func setPlaybackRate(_ rate: Float) throws {
        let player = try requirePlayer()
        player.setRate(rate)
        applyPlayback(player.currentSnapshot())
    }
}
