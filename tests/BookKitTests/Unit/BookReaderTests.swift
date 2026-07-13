import XCTest
@testable import BookKit

@MainActor
final class BookReaderTests: XCTestCase {
    func testUnifiedReaderNavigatesAndRestoresOneStateSnapshot() async throws {
        let store = InMemoryReaderStateStore()
        let book = makeFixedBook()
        let configuration = BookReader.Configuration(
            stateStore: store,
            preferences: ReaderPreferences(readingMode: .paginated)
        )
        let reader = try await BookReader(book: book, configuration: configuration)

        XCTAssertTrue(reader.supportsSpreads)
        XCTAssertFalse(reader.isAudiobook)
        XCTAssertNil(reader.playback)
        XCTAssertEqual(reader.position, .start)
        XCTAssertEqual(reader.pageCount, 3)

        try await reader.next()
        XCTAssertEqual(reader.position.spineIndex, 1)

        try await reader.setTheme(.dark)
        let bookmark = try await reader.addBookmark(note: "Middle")
        XCTAssertEqual(bookmark.position.spineIndex, 1)
        XCTAssertEqual(reader.bookmarks, [bookmark])
        await reader.shutdown()

        let restored = try await BookReader(book: book, configuration: configuration)
        XCTAssertEqual(restored.position.spineIndex, 1)
        XCTAssertEqual(restored.preferences.theme, .dark)
        XCTAssertEqual(restored.bookmarks, [bookmark])
        await restored.shutdown()
    }

    func testEveryEventSubscriberStartsReadyAndReceivesNavigation() async throws {
        let reader = try await BookReader(book: makeFixedBook())
        let first = reader.events
        let second = reader.events

        let firstTask = Task { () -> [BookReaderEvent] in
            var events: [BookReaderEvent] = []
            for await event in first {
                events.append(event)
                if case .locatorChanged = event { break }
            }
            return events
        }
        let secondTask = Task { () -> [BookReaderEvent] in
            var events: [BookReaderEvent] = []
            for await event in second {
                events.append(event)
                if case .locatorChanged = event { break }
            }
            return events
        }

        try await reader.next()

        let firstEvents = await firstTask.value
        let secondEvents = await secondTask.value
        XCTAssertEqual(firstEvents.first, .ready)
        XCTAssertEqual(secondEvents.first, .ready)
        XCTAssertTrue(firstEvents.contains { if case .locatorChanged = $0 { true } else { false } })
        XCTAssertTrue(secondEvents.contains { if case .locatorChanged = $0 { true } else { false } })
        await reader.shutdown()
    }

    func testAudiobookNavigationAndPreferencesShareOneStateOwner() async throws {
        let store = InMemoryReaderStateStore()
        let engine = BookReaderFakeAudioEngine()
        var configuration = BookReader.Configuration(
            stateStore: store,
            activatesRemoteCommands: false
        )
        configuration.audiobookEngine = engine
        let reader = try await BookReader(
            book: makeAudiobook(),
            configuration: configuration
        )

        XCTAssertTrue(reader.isAudiobook)
        XCTAssertEqual(reader.playback?.status, .ready)

        try await reader.setTheme(.dark)
        try await reader.next()
        try await reader.seek(toTimestamp: 7)

        let snapshot = try await store.loadState(forBookID: reader.book.id)
        XCTAssertEqual(snapshot?.position.spineIndex, 1)
        XCTAssertEqual(snapshot?.position.timestamp, 7)
        XCTAssertEqual(snapshot?.preferences.theme, .dark)
        await reader.shutdown()
    }

    #if canImport(SwiftUI)
    func testUnifiedViewConstructsForFixedReader() async throws {
        let reader = try await BookReader(book: makeFixedBook())
        _ = BookReaderView(reader: reader)
        await reader.shutdown()
    }
    #endif

    private func makeFixedBook() -> Book {
        Book(
            id: "unified-reader",
            format: .cbz,
            version: "1",
            metadata: Metadata(title: "Unified", authors: []),
            readingOrder: (0..<3).map { index in
                Chapter(
                    id: "page-\(index)",
                    href: "\(index).jpg",
                    title: "Page \(index + 1)",
                    content: "",
                    resourceID: "asset-\(index)",
                    mediaType: "image/jpeg",
                    page: PagePresentation(isCover: index == 0)
                )
            },
            assets: (0..<3).map { index in
                Asset(
                    id: "asset-\(index)",
                    href: "\(index).jpg",
                    mediaType: "image/jpeg",
                    data: Data([UInt8(index)])
                )
            },
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: [],
            presentation: BookPresentation(layout: .fixed)
        )
    }

    private func makeAudiobook() -> Book {
        Book(
            id: "unified-audio",
            format: .audiobook,
            version: "1",
            metadata: Metadata(title: "Audio", authors: []),
            readingOrder: [
                Chapter(
                    id: "track-1",
                    href: "one.mp3",
                    title: "One",
                    content: "",
                    resourceID: "audio-1",
                    mediaType: "audio/mpeg",
                    audio: AudioPresentation(duration: 30)
                ),
                Chapter(
                    id: "track-2",
                    href: "two.mp3",
                    title: "Two",
                    content: "",
                    resourceID: "audio-2",
                    mediaType: "audio/mpeg",
                    audio: AudioPresentation(duration: 30)
                ),
            ],
            assets: [
                Asset(id: "audio-1", href: "one.mp3", mediaType: "audio/mpeg", data: Data([1])),
                Asset(id: "audio-2", href: "two.mp3", mediaType: "audio/mpeg", data: Data([2])),
            ],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: [],
            presentation: BookPresentation(layout: .audiobook)
        )
    }
}

@MainActor
private final class BookReaderFakeAudioEngine: AudiobookPlaybackEngine {
    private let stream: AsyncStream<AudiobookEngineEvent>
    private let continuation: AsyncStream<AudiobookEngineEvent>.Continuation
    var duration: Double? = 30
    var isPlaying = false
    var rate: Float = 0
    var events: AsyncStream<AudiobookEngineEvent> { stream }

    init() {
        var continuation: AsyncStream<AudiobookEngineEvent>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func load(url _: URL, clipBegin _: Double, clipEnd _: Double?) async throws {
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

    func seek(to _: Double) {}

    func shutdown() {
        continuation.finish()
    }
}
