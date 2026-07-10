import XCTest
@testable import BookKit

@MainActor
final class AudiobookPlayerTests: XCTestCase {
    func testPreparePlaybackTimeEventsNavigationAndPersistence() async throws {
        let book = makeBook()
        let store = InMemoryReaderStateStore()
        let engine = FakeAudiobookEngine()
        let player = try AudiobookPlayer(book: book, stateStore: store, engine: engine)

        try await player.prepare()
        XCTAssertEqual(engine.loaded.count, 1)
        XCTAssertEqual(engine.loaded[0].clipBegin, 10)
        XCTAssertEqual(engine.seeks.last, 10)
        XCTAssertEqual(player.currentSnapshot().status, .ready)

        try await player.play()
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.rate, 1)

        engine.emit(.timeChanged(25))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(player.currentPosition().timestamp, 25)
        XCTAssertEqual(player.currentPosition().progression, 0.5)

        let movedToNextTrack = try await player.nextTrack()
        XCTAssertTrue(movedToNextTrack)
        XCTAssertEqual(player.currentPosition().spineIndex, 1)
        XCTAssertEqual(engine.loaded.count, 2)
        XCTAssertTrue(engine.isPlaying)

        try await player.seek(toTimestamp: 7)
        try await player.pause()
        XCTAssertFalse(engine.isPlaying)
        await player.shutdown()

        let restoringEngine = FakeAudiobookEngine()
        let restoredPlayer = try AudiobookPlayer(
            book: book,
            stateStore: store,
            engine: restoringEngine
        )
        try await restoredPlayer.prepare()
        XCTAssertEqual(restoredPlayer.currentPosition().spineIndex, 1)
        XCTAssertEqual(restoredPlayer.currentPosition().timestamp, 7)
        XCTAssertEqual(restoringEngine.seeks.last, 7)
        await restoredPlayer.shutdown()
    }

    func testPlaybackRateIsClampedAndAppliedLive() async throws {
        let engine = FakeAudiobookEngine()
        let player = try AudiobookPlayer(book: makeBook(), engine: engine)
        try await player.play()

        player.setRate(9)
        XCTAssertEqual(player.currentSnapshot().rate, 3)
        XCTAssertEqual(engine.rate, 3)

        player.setRate(0.1)
        XCTAssertEqual(player.currentSnapshot().rate, 0.5)
        XCTAssertEqual(engine.rate, 0.5)
        await player.shutdown()
    }

    func testNativeProtectionFailurePreventsPrepare() async throws {
        let engine = FakeAudiobookEngine()
        engine.loadError = .protectedContent(
            ContentProtection(kind: .audioDRM, scheme: "test DRM")
        )
        let player = try AudiobookPlayer(book: makeBook(), engine: engine)

        do {
            try await player.prepare()
            XCTFail("Expected protectedContent")
        } catch let BookError.protectedContent(protection) {
            XCTAssertEqual(protection.kind, .audioDRM)
        }
        await player.shutdown()
    }

    #if canImport(AVFoundation)
    func testAVFoundationEngineLoadsUnprotectedAudioAndReportsDuration() async throws {
        let mp3 = AudioTestFixture.silentMP3
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try mp3.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = AVFoundationAudiobookEngine()
        try await engine.load(url: url, clipBegin: 0, clipEnd: nil)
        XCTAssertGreaterThan(engine.duration ?? 0, 0)
        engine.seek(to: 0.02)
        engine.play(rate: 1.25)
        XCTAssertTrue(engine.isPlaying)
        engine.pause()
        XCTAssertFalse(engine.isPlaying)
        engine.shutdown()
    }
    #endif

    private func makeBook() -> Book {
        Book(
            id: "player-book",
            format: .audiobook,
            version: "1",
            metadata: Metadata(title: "Player", authors: ["Author"]),
            readingOrder: [
                Chapter(
                    id: "one",
                    href: "one.mp3",
                    title: "One",
                    content: "One",
                    resourceID: "asset-one",
                    mediaType: "audio/mpeg",
                    audio: AudioPresentation(duration: 30, clipBegin: 10, clipEnd: 40)
                ),
                Chapter(
                    id: "two",
                    href: "two.mp3",
                    title: "Two",
                    content: "Two",
                    resourceID: "asset-two",
                    mediaType: "audio/mpeg",
                    audio: AudioPresentation(duration: 20)
                ),
            ],
            assets: [
                Asset(id: "asset-one", href: "one.mp3", mediaType: "audio/mpeg", data: Data("one".utf8)),
                Asset(id: "asset-two", href: "two.mp3", mediaType: "audio/mpeg", data: Data("two".utf8)),
            ],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: [],
            presentation: BookPresentation(layout: .audiobook, spread: .none)
        )
    }

    private static let silentMP3Base64 = """
    SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjYyLjEyLjEwMAAAAAAAAAAAAAAA/+M4wAAAAAAAAAAAAEluZm8AAAAPAAAABAAAAxgAdHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0oqKioqKioqKioqKioqKioqKioqKioqKiotHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dH/////////////////////////////////AAAAAExhdmM2Mi4yOAAAAAAAAAAAAAAAACQDoAAAAAAAAAMYnchARgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/+MoxAAAAANIAAAAAExBTUVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+MoxHwAAANIAAAAAFVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+MoxHwAAANIAAAAAFVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+MoxHwAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
    """
}

@MainActor
private final class FakeAudiobookEngine: AudiobookPlaybackEngine {
    struct Load: Equatable {
        var url: URL
        var clipBegin: Double
        var clipEnd: Double?
    }

    private let stream: AsyncStream<AudiobookEngineEvent>
    private let continuation: AsyncStream<AudiobookEngineEvent>.Continuation
    private(set) var loaded: [Load] = []
    private(set) var seeks: [Double] = []
    var loadError: BookError?
    var duration: Double? = 30
    var isPlaying = false
    var rate: Float = 0
    var events: AsyncStream<AudiobookEngineEvent> { stream }

    init() {
        var captured: AsyncStream<AudiobookEngineEvent>.Continuation!
        stream = AsyncStream { captured = $0 }
        continuation = captured
    }

    func load(url: URL, clipBegin: Double, clipEnd: Double?) async throws {
        if let loadError { throw loadError }
        loaded.append(Load(url: url, clipBegin: clipBegin, clipEnd: clipEnd))
        duration = clipEnd.map { $0 - clipBegin } ?? duration
        continuation.yield(.ready(duration: duration))
    }

    func play(rate: Float) {
        isPlaying = true
        self.rate = rate
        continuation.yield(.playingChanged(true))
    }

    func pause() {
        isPlaying = false
        rate = 0
        continuation.yield(.playingChanged(false))
    }

    func seek(to timestamp: Double) {
        seeks.append(timestamp)
    }

    func emit(_ event: AudiobookEngineEvent) {
        continuation.yield(event)
    }

    func shutdown() {
        pause()
        continuation.finish()
    }
}
