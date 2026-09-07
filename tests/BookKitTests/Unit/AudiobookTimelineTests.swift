import XCTest
@testable import BookKit

final class AudiobookTimelineTests: XCTestCase {
    func testClampsTimeMapsGlobalProgressAndMovesBetweenTracks() throws {
        let timeline = try AudiobookTimeline(book: makeBook())

        XCTAssertEqual(timeline.trackCount, 2)
        XCTAssertEqual(timeline.totalDuration, 50)
        XCTAssertEqual(timeline.duration(ofTrackAt: 0), 30)
        XCTAssertEqual(timeline.duration(ofTrackAt: 1), 20)

        let first = timeline.position(trackIndex: 0, timestamp: 27.5)
        XCTAssertEqual(first.timestamp, 27.5)
        XCTAssertEqual(first.progression, 0.5)
        XCTAssertEqual(timeline.globalProgression(for: first), 0.3)

        let clamped = timeline.position(trackIndex: 0, timestamp: 200)
        XCTAssertEqual(clamped.timestamp, 42.5)
        XCTAssertEqual(clamped.progression, 1)

        let next = try XCTUnwrap(timeline.nextTrack(from: first))
        XCTAssertEqual(next.spineIndex, 1)
        XCTAssertEqual(next.timestamp, 0)
        XCTAssertNil(timeline.nextTrack(from: next))
        XCTAssertEqual(timeline.previousTrack(from: next)?.spineIndex, 0)
    }

    func testReaderPersistencePreservesTimestamp() async throws {
        let book = makeBook()
        let store = InMemoryReaderStateStore()
        let writer = ReaderStateActor(book: book, stateStore: store)
        try await writer.go(to: Position(spineIndex: 1, progression: 0.25, timestamp: 5))

        let reader = ReaderStateActor(book: book, stateStore: store)
        try await reader.restore()
        let restored = await reader.position
        XCTAssertEqual(restored.spineIndex, 1)
        XCTAssertEqual(restored.progression, 0.25)
        XCTAssertEqual(restored.timestamp, 5)
    }

    @MainActor
    func testContentRendererExposesAudioNavigationWithoutWebBridge() async throws {
        let renderer = try ContentRenderer(book: makeBook())
        XCTAssertEqual(renderer.mode, .audio)
        XCTAssertEqual(renderer.pageCount(), 2)
        try await renderer.renderChapter(at: 1, viewport: Viewport(width: 1, height: 1))
        let position = await renderer.currentPosition()
        XCTAssertEqual(position.spineIndex, 1)
        XCTAssertEqual(position.timestamp, 0)
    }

    func testDurationsUseEachTrackEvenWhenIDsRepeat() throws {
        var book = makeBook()
        book.readingOrder[1].id = book.readingOrder[0].id
        let timeline = try AudiobookTimeline(book: book)
        XCTAssertEqual(timeline.totalDuration, 50)
    }

    func testAudioSessionCleanupDoesNotRemoveOtherSessionFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var book = makeBook()
        book.readingOrder[0].resourceID = "audio"
        book.assets = [Asset(id: "audio", href: "one.mp3", mediaType: "audio/mpeg", data: AudioTestFixture.silentMP3)]
        let first = AudioResourceStore(book: book, options: OpenOptions(tempDirectory: directory))
        let second = AudioResourceStore(book: book, options: OpenOptions(tempDirectory: directory))
        let firstURL = try await first.url(forTrackAt: 0)
        let secondURL = try await second.url(forTrackAt: 0)
        XCTAssertNotEqual(firstURL, secondURL)
        try await first.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        let cached = try await second.url(forTrackAt: 0)
        XCTAssertEqual(try Data(contentsOf: cached), AudioTestFixture.silentMP3)
        try await second.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    private func makeBook() -> Book {
        Book(
            id: "audio",
            format: .audiobook,
            version: "1",
            metadata: Metadata(title: "Audio", authors: []),
            readingOrder: [
                Chapter(
                    id: "one",
                    href: "one.mp3#t=12.5,42.5",
                    title: "One",
                    content: "One",
                    mediaType: "audio/mpeg",
                    audio: AudioPresentation(duration: 30, clipBegin: 12.5, clipEnd: 42.5)
                ),
                Chapter(
                    id: "two",
                    href: "two.mp3",
                    title: "Two",
                    content: "Two",
                    mediaType: "audio/mpeg",
                    audio: AudioPresentation(duration: 20)
                ),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: [],
            presentation: BookPresentation(layout: .audiobook, spread: .none)
        )
    }
}
