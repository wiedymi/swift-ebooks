import Foundation

public struct PDFPageAdapter: Sendable {
    private let pageCountValue: Int

    public init(book: Book) {
        pageCountValue = max(book.readingOrder.count, 1)
    }

    public var pageCount: Int {
        pageCountValue
    }

    public func pageIndex(for position: Position) -> Int {
        min(max(position.spineIndex, 0), pageCountValue - 1)
    }

    public func position(forPageIndex index: Int) -> Position {
        Position(spineIndex: min(max(index, 0), pageCountValue - 1), progression: 0)
    }
}
