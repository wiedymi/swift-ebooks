import Foundation

enum BookPresentationEngine: Sendable, Equatable {
    case reflow
    case xhtmlFixed
    case bitmapFixed
    case pdf
    case audio

    init(book: Book) {
        if book.presentation.layout == .audiobook {
            self = .audio
        } else if book.format == .pdf {
            self = .pdf
        } else if book.presentation.layout == .fixed,
                  !book.readingOrder.isEmpty,
                  book.readingOrder.allSatisfy({ chapter in
                      chapter.resourceID != nil
                          && chapter.mediaType?.lowercased().hasPrefix("image/") == true
                  })
        {
            self = .bitmapFixed
        } else if book.presentation.layout == .fixed {
            self = .xhtmlFixed
        } else {
            self = .reflow
        }
    }

    var requiresReflowBridge: Bool {
        self == .reflow || self == .xhtmlFixed
    }
}
