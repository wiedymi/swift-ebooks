import Foundation

/// Maps normalized text offsets back to native text offsets, including PDF line breaks.
struct NormalizedText {
    let text: String
    private let offsets: [Int]

    init(_ source: String) {
        let units = Array(source.utf16)
        var output: [UInt16] = []
        var offsets: [Int] = []
        var space: Int?
        for (index, unit) in units.enumerated() {
            switch unit {
            case 9, 10, 12, 13, 32, 160:
                if space == nil { space = index }
            default:
                if !output.isEmpty, let space {
                    output.append(32)
                    offsets.append(space)
                }
                space = nil
                output.append(unit)
                offsets.append(index)
            }
        }
        text = String(decoding: output, as: UTF16.self)
        self.offsets = offsets
    }

    func originalRange(for target: ReaderTextRange) -> NSRange? {
        guard let range = resolve(target), range.length > 0 else { return nil }
        let start = offsets[range.location]
        return NSRange(location: start, length: offsets[range.location + range.length - 1] + 1 - start)
    }

    func location(forOriginalRange range: NSRange) -> ReaderTextRange? {
        guard range.location >= 0, range.length > 0,
            range.location <= Int.max - range.length
        else { return nil }
        let start = offsets.partitionIndex { $0 >= range.location }
        var end = offsets.partitionIndex { $0 >= range.location + range.length }
        var lower = start
        let source = text as NSString
        while lower < end, source.character(at: lower) == 32 { lower += 1 }
        while end > lower, source.character(at: end - 1) == 32 { end -= 1 }
        guard end > lower else { return nil }
        return BookText.range(in: text, range: NSRange(location: lower, length: end - lower))
    }

    func resolve(_ target: ReaderTextRange) -> NSRange? {
        let source = text as NSString
        guard !target.quote.isEmpty else { return nil }
        let quote = target.quote as NSString
        func contextMatches(_ start: Int) -> Bool {
            let end = start + quote.length
            let prefixLength = target.prefix.utf16.count
            let suffixLength = target.suffix.utf16.count
            guard prefixLength <= start, suffixLength <= source.length - end else { return false }
            return source.substring(with: NSRange(location: start - prefixLength, length: prefixLength))
                == target.prefix
                && source.substring(with: NSRange(location: end, length: suffixLength)) == target.suffix
        }
        if target.start >= 0, target.end > target.start, target.end <= source.length,
            source.substring(with: NSRange(location: target.start, length: target.end - target.start))
                == target.quote,
            contextMatches(target.start)
        {
            return NSRange(location: target.start, length: target.end - target.start)
        }
        var cursor = 0
        var best: NSRange?
        var bestScore = -1
        var tied = false
        let prefix = Array(target.prefix.utf16)
        let suffix = Array(target.suffix.utf16)
        while cursor < source.length {
            let match = source.range(
                of: target.quote, options: .literal,
                range: NSRange(location: cursor, length: source.length - cursor))
            if match.location == NSNotFound { break }
            var score = 0
            for n in 0..<min(prefix.count, match.location) {
                if source.character(at: match.location - n - 1) != prefix[prefix.count - n - 1] { break }
                score += 1
            }
            let end = match.location + match.length
            for n in 0..<min(suffix.count, source.length - end) {
                if source.character(at: end + n) != suffix[n] { break }
                score += 1
            }
            if score > bestScore {
                best = match
                bestScore = score
                tied = false
            } else if score == bestScore {
                tied = true
            }
            cursor = match.location + 1
        }
        return tied ? nil : best
    }
}

extension Array where Element == Int {
    fileprivate func partitionIndex(where predicate: (Int) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = low + (high - low) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
