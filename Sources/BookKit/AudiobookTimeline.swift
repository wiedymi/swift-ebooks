import Foundation

struct AudiobookTimeline: Sendable {
    public let book: Book

    public init(book: Book) throws {
        guard book.presentation.layout == .audiobook else {
            throw BookError.navigationFailed("Book is not an audiobook")
        }
        self.book = book
    }

    public var trackCount: Int {
        book.readingOrder.count
    }

    public var totalDuration: Double {
        book.readingOrder.reduce(0) { $0 + effectiveDuration($1) }
    }

    public func duration(ofTrackAt index: Int) -> Double {
        guard book.readingOrder.indices.contains(index) else { return 0 }
        return effectiveDuration(book.readingOrder[index])
    }

    public func position(trackIndex: Int, timestamp: Double) -> Position {
        guard !book.readingOrder.isEmpty else { return .start }
        let index = min(max(trackIndex, 0), book.readingOrder.count - 1)
        let chapter = book.readingOrder[index]
        let begin = chapter.audio?.clipBegin ?? 0
        let duration = effectiveDuration(chapter)
        let upper = duration > 0 ? begin + duration : max(timestamp, begin)
        let clampedTime = min(max(timestamp, begin), upper)
        let progression = duration > 0 ? (clampedTime - begin) / duration : 0
        return Position(
            spineIndex: index,
            progression: min(max(progression, 0), 1),
            timestamp: clampedTime
        )
    }

    public func startPosition(ofTrackAt index: Int) -> Position {
        guard book.readingOrder.indices.contains(index) else { return position(trackIndex: index, timestamp: 0) }
        return position(
            trackIndex: index,
            timestamp: book.readingOrder[index].audio?.clipBegin ?? 0
        )
    }

    public func nextTrack(from position: Position) -> Position? {
        guard position.spineIndex + 1 < book.readingOrder.count else { return nil }
        return startPosition(ofTrackAt: position.spineIndex + 1)
    }

    public func previousTrack(from position: Position) -> Position? {
        guard position.spineIndex > 0 else { return nil }
        return startPosition(ofTrackAt: position.spineIndex - 1)
    }

    public func globalProgression(for position: Position) -> Double {
        let total = totalDuration
        guard total > 0, !book.readingOrder.isEmpty else { return 0 }
        let index = min(max(position.spineIndex, 0), book.readingOrder.count - 1)
        let preceding = (0..<index).reduce(0.0) { $0 + duration(ofTrackAt: $1) }
        let chapter = book.readingOrder[index]
        let begin = chapter.audio?.clipBegin ?? 0
        let localDuration = duration(ofTrackAt: index)
        let timestamp = position.timestamp ?? begin + position.progression * localDuration
        let local = min(max(timestamp - begin, 0), localDuration)
        return min(max((preceding + local) / total, 0), 1)
    }

    private func effectiveDuration(_ chapter: Chapter) -> Double {
        let begin = chapter.audio?.clipBegin ?? 0
        if let end = chapter.audio?.clipEnd, end >= begin {
            return end - begin
        }
        return max(chapter.audio?.duration ?? 0, 0)
    }
}
