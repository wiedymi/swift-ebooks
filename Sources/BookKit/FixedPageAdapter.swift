import Foundation

public struct FixedPageSpread: Sendable, Equatable, Hashable {
    public var pageIndices: [Int]

    public init(pageIndices: [Int]) {
        self.pageIndices = pageIndices
    }
}

public struct FixedPageAdapter: Sendable {
    public let book: Book

    public init(book: Book) {
        self.book = book
    }

    public var pageCount: Int {
        max(book.readingOrder.count, 1)
    }

    public func position(forPageIndex pageIndex: Int) -> Position {
        guard !book.readingOrder.isEmpty else { return .start }
        return Position(
            spineIndex: min(max(pageIndex, 0), book.readingOrder.count - 1),
            progression: 0
        )
    }

    public func pageIndex(for position: Position) -> Int {
        guard !book.readingOrder.isEmpty else { return 0 }
        return min(max(position.spineIndex, 0), book.readingOrder.count - 1)
    }

    public func asset(forPageIndex pageIndex: Int) -> Asset? {
        guard book.readingOrder.indices.contains(pageIndex) else { return nil }
        let chapter = book.readingOrder[pageIndex]
        if let resourceID = chapter.resourceID,
           let asset = book.assets.first(where: { $0.id == resourceID })
        {
            return asset
        }
        return book.assets.first { $0.href == chapter.href }
    }

    public func spreads(enabled: Bool = true) -> [FixedPageSpread] {
        guard !book.readingOrder.isEmpty else { return [FixedPageSpread(pageIndices: [0])] }
        guard enabled, book.presentation.spread != .none else {
            return book.readingOrder.indices.map { FixedPageSpread(pageIndices: [$0]) }
        }

        var result: [FixedPageSpread] = []
        var index = 0
        while index < book.readingOrder.count {
            let page = book.readingOrder[index].page
            if page?.isCover == true || page?.isSpread == true || page?.side == .center {
                result.append(FixedPageSpread(pageIndices: [index]))
                index += 1
                continue
            }

            let nextIndex = index + 1
            if nextIndex < book.readingOrder.count {
                let next = book.readingOrder[nextIndex].page
                let canPair = next?.isCover != true && next?.isSpread != true && next?.side != .center
                if canPair {
                    let pair = book.presentation.readingProgression == .rightToLeft
                        ? [nextIndex, index]
                        : [index, nextIndex]
                    result.append(FixedPageSpread(pageIndices: pair))
                    index += 2
                    continue
                }
            }
            result.append(FixedPageSpread(pageIndices: [index]))
            index += 1
        }
        return result
    }
}
