import XCTest
@testable import BookKit

final class ReaderStateStoreTests: XCTestCase {
    func testInMemoryStoreReaderRestoreRoundTrip() async throws {
        let book = makeBook(id: "book-memory")
        let store = InMemoryReaderStateStore()

        let reader1 = ReaderStateActor(book: book, stateStore: store)
        try await reader1.go(to: Position(spineIndex: 1, progression: 0.42))
        _ = try await reader1.addBookmark(note: "Checkpoint")

        let reader2 = ReaderStateActor(book: book, stateStore: store)
        try await reader2.restore()

        let restoredPosition = await reader2.position
        XCTAssertEqual(restoredPosition.spineIndex, 1)
        XCTAssertEqual(restoredPosition.progression, 0.42, accuracy: 0.0001)

        let restoredBookmarks = await reader2.bookmarksList()
        XCTAssertEqual(restoredBookmarks.count, 1)
        XCTAssertEqual(restoredBookmarks.first?.note, "Checkpoint")
        XCTAssertEqual(restoredBookmarks.first?.position.spineIndex, 1)
    }

    func testReaderBookmarkCRUDPersists() async throws {
        let book = makeBook(id: "book-crud")
        let store = InMemoryReaderStateStore()
        let reader = ReaderStateActor(book: book, stateStore: store)

        let bookmark1 = try await reader.addBookmark(note: "First")
        let bookmark2 = try await reader.addBookmark(note: "Second")
        try await reader.updateBookmark(id: bookmark1.id, note: "Updated")
        try await reader.removeBookmark(id: bookmark2.id)

        let bookmarks = await reader.bookmarksList()
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.id, bookmark1.id)
        XCTAssertEqual(bookmarks.first?.note, "Updated")

        let snapshot = try await store.loadState(forBookID: book.id)
        XCTAssertEqual(snapshot?.bookmarks.count, 1)
        XCTAssertEqual(snapshot?.bookmarks.first?.note, "Updated")
    }

    func testFileReaderStateStoreRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileReaderStateStore(directory: dir)
        let bookmark = ReadingBookmark(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            position: Position(spineIndex: 0, progression: 0.7),
            note: "Saved"
        )
        let snapshot = ReaderSnapshot(
            bookID: "book-file",
            position: Position(spineIndex: 1, progression: 0.1),
            bookmarks: [bookmark],
            updatedAt: Date(timeIntervalSince1970: 123)
        )

        try await store.saveState(snapshot)
        let loaded = try await store.loadState(forBookID: "book-file")

        let loadedProgression = try XCTUnwrap(loaded?.position.progression)
        XCTAssertEqual(loaded?.bookID, "book-file")
        XCTAssertEqual(loaded?.position.spineIndex, 1)
        XCTAssertEqual(loadedProgression, 0.1, accuracy: 0.0001)
        XCTAssertEqual(loaded?.bookmarks.first?.id, bookmark.id)
        XCTAssertEqual(loaded?.bookmarks.first?.note, "Saved")
    }

    func testNextPagePersistsWhenStayingInSameChapter() async throws {
        let book = makeBook(id: "book-page-persist")
        let store = InMemoryReaderStateStore()
        let reader = ReaderStateActor(book: book, pageCharacterCount: 10, stateStore: store)

        try await reader.nextPage()

        let snapshot = try await store.loadState(forBookID: book.id)
        XCTAssertEqual(snapshot?.position.spineIndex, 0)
        XCTAssertGreaterThan(snapshot?.position.progression ?? 0, 0)
    }

    func testReaderPreferencesPersistInSnapshot() async throws {
        let book = makeBook(id: "book-preferences")
        let store = InMemoryReaderStateStore()
        let reader = ReaderStateActor(book: book, stateStore: store)

        try await reader.setPreferences(
            ReaderPreferences(
                readingMode: .paginated,
                theme: .dark,
                typography: Typography(
                    fontFamily: "Georgia",
                    fontSize: 19,
                    lineHeight: 1.7,
                    letterSpacing: 0.15
                )
            )
        )

        let snapshot = try await store.loadState(forBookID: book.id)
        XCTAssertEqual(snapshot?.preferences.readingMode, .paginated)
        XCTAssertEqual(snapshot?.preferences.theme, .dark)
        XCTAssertEqual(snapshot?.preferences.typography.fontFamily, "Georgia")
        XCTAssertEqual(try XCTUnwrap(snapshot?.preferences.typography.fontSize), 19, accuracy: 0.0001)
    }

    private func makeBook(id: String) -> Book {
        Book(
            id: id,
            format: .epub,
            version: "1",
            metadata: Metadata(title: "T", authors: []),
            readingOrder: [
                Chapter(id: "c1", href: "c1", title: "C1", content: String(repeating: "a", count: 100)),
                Chapter(id: "c2", href: "c2", title: "C2", content: String(repeating: "b", count: 100)),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )
    }
}
