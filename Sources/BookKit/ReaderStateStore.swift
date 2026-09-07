import CryptoKit
import Foundation

public struct ReadingBookmark: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var position: Position
    public var note: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        position: Position,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.position = position
        self.note = note
        self.createdAt = createdAt
    }
}

public struct ReaderSnapshot: Sendable, Equatable, Codable {
    public var bookID: String
    public var position: Position
    public var bookmarks: [ReadingBookmark]
    public var preferences: ReaderPreferences
    public var updatedAt: Date

    public init(
        bookID: String,
        position: Position,
        bookmarks: [ReadingBookmark],
        preferences: ReaderPreferences = .default,
        updatedAt: Date = Date()
    ) {
        self.bookID = bookID
        self.position = position
        self.bookmarks = bookmarks
        self.preferences = preferences
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case bookID
        case position
        case bookmarks
        case preferences
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookID = try container.decode(String.self, forKey: .bookID)
        position = try container.decode(Position.self, forKey: .position)
        bookmarks = try container.decode([ReadingBookmark].self, forKey: .bookmarks)
        preferences = try container.decodeIfPresent(ReaderPreferences.self, forKey: .preferences) ?? .default
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bookID, forKey: .bookID)
        try container.encode(position, forKey: .position)
        try container.encode(bookmarks, forKey: .bookmarks)
        try container.encode(preferences, forKey: .preferences)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

public protocol ReaderStateStore: Sendable {
    func loadState(forBookID bookID: String) async throws -> ReaderSnapshot?
    func saveState(_ snapshot: ReaderSnapshot) async throws
}

public actor InMemoryReaderStateStore: ReaderStateStore {
    private var snapshotsByBookID: [String: ReaderSnapshot] = [:]

    public init() {}

    public func loadState(forBookID bookID: String) async throws -> ReaderSnapshot? {
        snapshotsByBookID[bookID]
    }

    public func saveState(_ snapshot: ReaderSnapshot) async throws {
        snapshotsByBookID[snapshot.bookID] = snapshot
    }
}

public actor FileReaderStateStore: ReaderStateStore {
    private let directory: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(directory: URL) {
        self.directory = directory
        encoder.outputFormatting = [.sortedKeys]
    }

    public func loadState(forBookID bookID: String) async throws -> ReaderSnapshot? {
        var url = stateFileURL(forBookID: bookID)
        if !FileManager.default.fileExists(atPath: url.path) {
            // Older versions used two filename characters per UTF-8 byte.
            guard bookID.utf8.count <= 125 else { return nil }
            url = directory.appendingPathComponent(hexEncodedUTF8(bookID)).appendingPathExtension("json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        }
        let data = try Data(contentsOf: url)
        let snapshot = try decoder.decode(ReaderSnapshot.self, from: data)
        guard snapshot.bookID == bookID else {
            throw BookError.io("Saved state belongs to another book")
        }
        return snapshot
    }

    public func saveState(_ snapshot: ReaderSnapshot) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: stateFileURL(forBookID: snapshot.bookID), options: .atomic)
    }

    private func stateFileURL(forBookID bookID: String) -> URL {
        let name = SHA256.hash(data: Data(bookID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    private func hexEncodedUTF8(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }
}
