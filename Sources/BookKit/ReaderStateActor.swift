import Foundation

actor ReaderStateActor {
    private let book: Book
    private let pageCharacterCount: Int
    private let stateStore: (any ReaderStateStore)?

    private(set) var position: Position
    private(set) var bookmarks: [ReadingBookmark]
    private var preferences: ReaderPreferences
    private var pendingWrite: Task<Void, Error>?

    init(
        book: Book,
        pageCharacterCount: Int = 1200,
        stateStore: (any ReaderStateStore)? = nil,
        preferences: ReaderPreferences = .default
    ) {
        self.book = book
        self.pageCharacterCount = max(pageCharacterCount, 1)
        self.stateStore = stateStore
        self.position = Position(spineIndex: 0, progression: 0)
        self.bookmarks = []
        self.preferences = preferences
    }

    func restore() async throws {
        guard let stateStore else {
            return
        }

        guard let snapshot = try await stateStore.loadState(forBookID: book.id) else {
            return
        }

        position = Self.clamp(position: snapshot.position, chapterCount: book.readingOrder.count)
        bookmarks = snapshot.bookmarks
            .map { bookmark in
                var normalized = bookmark
                normalized.position = Self.clamp(position: bookmark.position, chapterCount: book.readingOrder.count)
                return normalized
            }
            .sorted { $0.createdAt < $1.createdAt }
        preferences = snapshot.preferences
    }

    func go(to position: Position) async throws {
        self.position = Self.clamp(position: position, chapterCount: book.readingOrder.count)
        try await persist()
    }

    func nextPage() async throws {
        guard !book.readingOrder.isEmpty else {
            return
        }

        var pos = position
        let chapter = book.readingOrder[pos.spineIndex]
        let chapterLength = max(chapter.content.count, 1)
        let currentOffset = Int(Double(chapterLength) * min(max(pos.progression, 0), 1))
        let nextOffset = currentOffset + min(pageCharacterCount, chapterLength - currentOffset)

        if nextOffset < chapterLength {
            pos.progression = Double(nextOffset) / Double(chapterLength)
            position = pos
            try await persist()
            return
        }

        if pos.spineIndex + 1 < book.readingOrder.count {
            pos.spineIndex += 1
            pos.progression = 0
        } else {
            pos.progression = 1
        }
        position = pos
        try await persist()
    }

    func previousPage() async throws {
        guard !book.readingOrder.isEmpty else {
            return
        }

        var pos = position
        let chapter = book.readingOrder[pos.spineIndex]
        let chapterLength = max(chapter.content.count, 1)
        let currentOffset = Int(Double(chapterLength) * min(max(pos.progression, 0), 1))
        let previousOffset = currentOffset - pageCharacterCount

        if previousOffset >= 0 {
            pos.progression = Double(previousOffset) / Double(chapterLength)
            position = pos
            try await persist()
            return
        }

        if pos.spineIndex > 0 {
            pos.spineIndex -= 1
            pos.progression = 1
        } else {
            pos.progression = 0
        }
        position = pos
        try await persist()
    }

    func addBookmark(note: String? = nil) async throws -> ReadingBookmark {
        let bookmark = ReadingBookmark(position: position, note: note)
        bookmarks.append(bookmark)
        bookmarks.sort { $0.createdAt < $1.createdAt }
        try await persist()
        return bookmark
    }

    func updateBookmark(id: UUID, note: String?) async throws {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else {
            return
        }
        bookmarks[index].note = note
        try await persist()
    }

    func removeBookmark(id: UUID) async throws {
        bookmarks.removeAll { $0.id == id }
        try await persist()
    }

    func bookmark(id: UUID) -> ReadingBookmark? {
        bookmarks.first { $0.id == id }
    }

    func bookmarksList() -> [ReadingBookmark] {
        bookmarks
    }

    func setPreferences(_ preferences: ReaderPreferences) async throws {
        self.preferences = preferences
        try await persist()
    }

    func currentPreferences() -> ReaderPreferences {
        preferences
    }

    func sync(to position: Position) {
        self.position = Self.clamp(position: position, chapterCount: book.readingOrder.count)
    }

    private static func clamp(position: Position, chapterCount: Int) -> Position {
        guard chapterCount > 0 else {
            return Position(
                spineIndex: 0,
                progression: 0,
                cfi: position.cfi,
                fragment: position.fragment,
                textContext: position.textContext,
                timestamp: position.timestamp,
                textRange: position.textRange
            )
        }

        let index = min(max(position.spineIndex, 0), chapterCount - 1)
        let progression = position.progression.isFinite ? min(max(position.progression, 0), 1) : 0
        return Position(
            spineIndex: index,
            progression: progression,
            cfi: position.cfi,
            fragment: position.fragment,
            textContext: position.textContext,
            timestamp: position.timestamp,
            textRange: position.textRange
        )
    }

    func persist() async throws {
        guard let stateStore else {
            return
        }

        let snapshot = ReaderSnapshot(
            bookID: book.id,
            position: position,
            bookmarks: bookmarks,
            preferences: preferences,
            updatedAt: Date()
        )
        let previous = pendingWrite
        let write = Task {
            _ = await previous?.result
            try await stateStore.saveState(snapshot)
        }
        pendingWrite = write
        try await write.value
    }
}
