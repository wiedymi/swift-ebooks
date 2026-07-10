import Foundation

struct DjVuJB2Bitmap: Sendable, Equatable {
    let width: Int
    let height: Int
    /// Zero is white and one is black, in top-to-bottom row order.
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) throws {
        guard width >= 0, height >= 0,
              width == 0 || height <= Int.max / max(width, 1),
              pixels.count == width * height
        else {
            throw BookError.malformedDocument("DjVu JB2 bitmap dimensions are inconsistent")
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    func pixel(x: Int, y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return pixels[y * width + x]
    }

    func croppedToBlackPixels() throws -> DjVuJB2Bitmap {
        guard let firstBlack = pixels.firstIndex(of: 1) else {
            return try DjVuJB2Bitmap(width: 0, height: 0, pixels: [])
        }
        var minX = firstBlack % width
        var maxX = minX
        var minY = firstBlack / width
        var maxY = minY
        for index in pixels.indices where pixels[index] != 0 {
            let x = index % width
            let y = index / width
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
        let croppedWidth = maxX - minX + 1
        let croppedHeight = maxY - minY + 1
        var cropped = [UInt8](repeating: 0, count: croppedWidth * croppedHeight)
        for y in 0..<croppedHeight {
            let sourceStart = (minY + y) * width + minX
            let destinationStart = y * croppedWidth
            cropped.replaceSubrange(
                destinationStart..<(destinationStart + croppedWidth),
                with: pixels[sourceStart..<(sourceStart + croppedWidth)]
            )
        }
        return try DjVuJB2Bitmap(width: croppedWidth, height: croppedHeight, pixels: cropped)
    }
}

struct DjVuJB2Image: Sendable, Equatable {
    let width: Int
    let height: Int
    let mask: [UInt8]
    /// The zero-based JB2 blit that most recently painted each foreground pixel.
    let blitMap: [Int32]
    let blitCount: Int
    let symbols: [DjVuJB2Bitmap]
}

enum DjVuJB2Decoder {
    static func decodeImage(
        _ data: Data,
        sharedSymbols: [DjVuJB2Bitmap] = [],
        expectedWidth: Int? = nil,
        expectedHeight: Int? = nil,
        maxOutputBytes: Int,
        maxRecords: Int
    ) throws -> DjVuJB2Image {
        var state = State(
            data: data,
            mode: .image,
            sharedSymbols: sharedSymbols,
            maxOutputBytes: maxOutputBytes,
            maxRecords: maxRecords
        )
        let result = try state.decode()
        if let expectedWidth, result.width != expectedWidth {
            throw BookError.malformedDocument("DjVu JB2 width does not match the page INFO chunk")
        }
        if let expectedHeight, result.height != expectedHeight {
            throw BookError.malformedDocument("DjVu JB2 height does not match the page INFO chunk")
        }
        return result
    }

    static func decodeDictionary(
        _ data: Data,
        inheritedSymbols: [DjVuJB2Bitmap] = [],
        maxOutputBytes: Int,
        maxRecords: Int
    ) throws -> [DjVuJB2Bitmap] {
        var state = State(
            data: data,
            mode: .dictionary,
            sharedSymbols: inheritedSymbols,
            maxOutputBytes: maxOutputBytes,
            maxRecords: maxRecords
        )
        return try state.decode().symbols
    }
}

private extension DjVuJB2Decoder {
    enum Mode {
        case image
        case dictionary
    }

    enum NumberContext: Int, CaseIterable {
        case recordType
        case imageSize
        case matchingSymbolIndex
        case symbolWidth
        case symbolHeight
        case symbolWidthDifference
        case symbolHeightDifference
        case symbolColumn
        case symbolRow
        case sameLineColumnOffset
        case sameLineRowOffset
        case newLineColumnOffset
        case newLineRowOffset
        case commentLength
        case commentOctet
        case dictionarySize
    }

    struct IntegerContext {
        var states: [UInt64: UInt8] = [:]

        mutating func decode(
            lowerBound: Int,
            upperBound: Int,
            arithmetic: inout DjVuZPDecoder
        ) throws -> Int {
            guard lowerBound <= upperBound else {
                throw BookError.malformedDocument("DjVu JB2 numeric range is empty")
            }
            if lowerBound == upperBound { return lowerBound }

            let negativeAllowed = lowerBound < 0
            let nonnegativeAllowed = upperBound >= 0
            let isNonnegative: Bool
            var node: UInt64 = 1
            if negativeAllowed, nonnegativeAllowed {
                isNonnegative = try decodeBit(at: node, arithmetic: &arithmetic) == 1
            } else {
                isNonnegative = nonnegativeAllowed
            }
            node = try child(of: node, bit: isNonnegative ? 1 : 0)

            let allowedV: ClosedRange<Int>
            if isNonnegative {
                guard nonnegativeAllowed else {
                    throw BookError.malformedDocument("DjVu JB2 number sign exceeds its range")
                }
                allowedV = max(lowerBound, 0)...upperBound
            } else {
                guard negativeAllowed else {
                    throw BookError.malformedDocument("DjVu JB2 number sign exceeds its range")
                }
                let highestNegative = min(upperBound, -1)
                allowedV = (-highestNegative - 1)...(-lowerBound - 1)
            }

            var rangeStart = 0
            var rangeSize = 1
            var selectedRange: ClosedRange<Int>?
            for _ in 0..<19 {
                let rangeEnd = rangeStart + rangeSize - 1
                let remainingLowerBound = max(allowedV.lowerBound, rangeStart)
                let intersects = remainingLowerBound <= rangeEnd
                let containsRemainingValues = intersects && allowedV.upperBound <= rangeEnd
                let selected: Bool
                if containsRemainingValues {
                    selected = true
                } else if !intersects {
                    selected = false
                } else {
                    let rawBit = try decodeBit(at: node, arithmetic: &arithmetic)
                    selected = rawBit == 0
                }
                node = try child(of: node, bit: selected ? 0 : 1)
                if selected {
                    guard intersects else {
                        throw BookError.malformedDocument("DjVu JB2 number selects an excluded range")
                    }
                    selectedRange = max(rangeStart, allowedV.lowerBound)...min(rangeEnd, allowedV.upperBound)
                    break
                }
                guard allowedV.upperBound > rangeEnd else {
                    throw BookError.malformedDocument("DjVu JB2 number skips its allowable range")
                }
                rangeStart += rangeSize
                rangeSize *= 2
            }

            guard let selectedRange else {
                throw BookError.malformedDocument("DjVu JB2 number exceeds the specified maximum")
            }
            var candidateRange = rangeStart...(rangeStart + rangeSize - 1)
            while candidateRange.lowerBound < candidateRange.upperBound {
                let midpoint = candidateRange.lowerBound
                    + (candidateRange.upperBound - candidateRange.lowerBound) / 2
                let bit: Int
                if selectedRange.upperBound <= midpoint {
                    bit = 0
                } else if selectedRange.lowerBound > midpoint {
                    bit = 1
                } else {
                    bit = try decodeBit(at: node, arithmetic: &arithmetic)
                }
                node = try child(of: node, bit: bit)
                candidateRange = bit == 0
                    ? candidateRange.lowerBound...midpoint
                    : (midpoint + 1)...candidateRange.upperBound
                guard candidateRange.overlaps(selectedRange) else {
                    throw BookError.malformedDocument("DjVu JB2 number leaves its allowable range")
                }
            }

            let value = candidateRange.lowerBound
            return isNonnegative ? value : -value - 1
        }

        private mutating func decodeBit(
            at node: UInt64,
            arithmetic: inout DjVuZPDecoder
        ) throws -> Int {
            var state = states[node] ?? 0
            let bit = try arithmetic.decode(state: &state)
            states[node] = state
            return bit
        }

        private func child(of node: UInt64, bit: Int) throws -> UInt64 {
            guard node <= (UInt64.max - 1) / 2 else {
                throw BookError.malformedDocument("DjVu JB2 numeric context tree is too deep")
            }
            return node * 2 + UInt64(bit)
        }
    }

    struct Placement {
        let left: Int
        let top: Int
        let width: Int
        let height: Int

        var right: Int { left + width - 1 }
        var bottom: Int { top - height + 1 }
    }

    struct State {
        let mode: Mode
        let inheritedSymbolCount: Int
        let maxOutputBytes: Int
        let maxRecords: Int
        var arithmetic: DjVuZPDecoder
        var numbers = [IntegerContext](repeating: IntegerContext(), count: NumberContext.allCases.count)
        var directContexts = [UInt8](repeating: 0, count: 1024)
        var refinementContexts = [UInt8](repeating: 0, count: 2048)
        var eventualRefinementContext: UInt8 = 0
        var offsetTypeContext: UInt8 = 0
        var symbols: [DjVuJB2Bitmap]
        var width = 0
        var height = 0
        var mask: [UInt8] = []
        var blitMap: [Int32] = []
        var blitCount = 0
        var started = false
        var firstOnLine: Placement?
        var previousOnLine: Placement?
        var recentBottoms: [Int] = []
        var decodedSymbolPixels = 0

        init(
            data: Data,
            mode: Mode,
            sharedSymbols: [DjVuJB2Bitmap],
            maxOutputBytes: Int,
            maxRecords: Int
        ) {
            self.mode = mode
            inheritedSymbolCount = sharedSymbols.count
            self.maxOutputBytes = max(maxOutputBytes, 1)
            self.maxRecords = max(maxRecords, 1)
            arithmetic = DjVuZPDecoder(data: data, contextCount: 0)
            symbols = sharedSymbols
        }

        mutating func decode() throws -> DjVuJB2Image {
            for recordIndex in 0..<maxRecords {
                let recordType: Int
                do {
                    recordType = try number(.recordType, 0...11)
                } catch where started && arithmetic.hasExhaustedInput {
                    return try finishedImage()
                }
                if !started, recordType != 0, recordType != 9, recordType != 10 {
                    throw BookError.malformedDocument("DjVu JB2 data begins with record type \(recordType), not an image record")
                }

                switch recordType {
                case 0:
                    guard !started else {
                        throw BookError.malformedDocument("DjVu JB2 contains multiple start records")
                    }
                    try decodeStart()
                case 1, 2, 3:
                    try decodeDirectSymbol(recordType: recordType)
                case 4, 5, 6:
                    try decodeRefinedSymbol(recordType: recordType)
                case 7:
                    try decodeCopiedSymbol()
                case 8:
                    try decodeNonSymbolData()
                case 9:
                    if started {
                        resetNumberContexts()
                    } else {
                        let required = try number(.dictionarySize, 0...262_142)
                        guard required == inheritedSymbolCount else {
                            throw BookError.malformedDocument(
                                "DjVu JB2 requires (required) shared symbols but (inheritedSymbolCount) were supplied"
                            )
                        }
                    }
                case 10:
                    try decodeComment()
                case 11:
                    guard started else {
                        throw BookError.malformedDocument("DjVu JB2 ends before its start record")
                    }
                    return try finishedImage()
                default:
                    throw BookError.malformedDocument("DjVu JB2 record type is invalid")
                }


                if recordIndex == maxRecords - 1 {
                    throw BookError.malformedDocument("DjVu JB2 record count exceeds the configured limit")
                }
            }
            throw BookError.malformedDocument("DjVu JB2 stream has no end record")
        }

        func finishedImage() throws -> DjVuJB2Image {
            if mode == .image, width * height != mask.count || mask.count != blitMap.count {
                throw BookError.malformedDocument("DjVu JB2 image mask is incomplete")
            }
            return DjVuJB2Image(
                width: width,
                height: height,
                mask: mask,
                blitMap: blitMap,
                blitCount: blitCount,
                symbols: symbols
            )
        }

        mutating func decodeStart() throws {
            width = try number(.imageSize, 0...262_142)
            height = try number(.imageSize, 0...262_142)
            guard width > 0 || mode == .dictionary,
                  height > 0 || mode == .dictionary,
                  width == 0 || height <= Int.max / max(width, 1),
                  width * height <= maxOutputBytes
            else {
                throw BookError.malformedDocument("DjVu JB2 image dimensions exceed the configured limit")
            }
            if mode == .image {
                mask = [UInt8](repeating: 0, count: width * height)
                blitMap = [Int32](repeating: -1, count: width * height)
            }
            let eventualRefinement = try arithmetic.decode(state: &eventualRefinementContext)
            guard eventualRefinement == 0 else {
                throw BookError.renderingFailed("DjVu JB2 eventual image refinement is not supported")
            }
            started = true
        }

        mutating func decodeDirectSymbol(recordType: Int) throws {
            guard started else {
                throw BookError.malformedDocument("DjVu JB2 symbol precedes the start record")
            }
            let bitmapWidth = try number(.symbolWidth, 0...262_142)
            let bitmapHeight = try number(.symbolHeight, 0...262_142)
            let bitmap = try decodeDirectBitmap(width: bitmapWidth, height: bitmapHeight)
            let addToImage = recordType == 1 || recordType == 3
            let addToLibrary = recordType == 1 || recordType == 2
            if mode == .dictionary, addToImage {
                throw BookError.malformedDocument("DjVu JB2 dictionary contains an image-placement record")
            }
            if addToImage {
                let placement = try decodeRelativePlacement(width: bitmap.width, height: bitmap.height)
                place(bitmap, at: placement)
            }
            if addToLibrary {
                try appendSymbol(bitmap.croppedToBlackPixels())
            }
        }

        mutating func decodeRefinedSymbol(recordType: Int) throws {
            guard started, !symbols.isEmpty else {
                throw BookError.malformedDocument("DjVu JB2 refinement has no matching symbol")
            }
            let matchIndex = try number(.matchingSymbolIndex, 0...(symbols.count - 1))
            let match = symbols[matchIndex]
            let widthDifference = try number(.symbolWidthDifference, -262_143...262_142)
            let heightDifference = try number(.symbolHeightDifference, -262_143...262_142)
            let bitmapWidth = match.width + widthDifference
            let bitmapHeight = match.height + heightDifference
            guard bitmapWidth >= 0, bitmapHeight >= 0 else {
                throw BookError.malformedDocument("DjVu JB2 refined symbol has negative dimensions")
            }
            let bitmap = try decodeRefinedBitmap(
                width: bitmapWidth,
                height: bitmapHeight,
                matching: match
            )
            let addToImage = recordType == 4 || recordType == 6
            let addToLibrary = recordType == 4 || recordType == 5
            if mode == .dictionary, addToImage {
                throw BookError.malformedDocument("DjVu JB2 dictionary contains an image-placement record")
            }
            if addToImage {
                let placement = try decodeRelativePlacement(width: bitmap.width, height: bitmap.height)
                place(bitmap, at: placement)
            }
            if addToLibrary {
                try appendSymbol(bitmap.croppedToBlackPixels())
            }
        }

        mutating func decodeCopiedSymbol() throws {
            guard started, mode == .image, !symbols.isEmpty else {
                throw BookError.malformedDocument("DjVu JB2 copy has no matching symbol")
            }
            let matchIndex = try number(.matchingSymbolIndex, 0...(symbols.count - 1))
            let bitmap = symbols[matchIndex]
            let placement = try decodeRelativePlacement(width: bitmap.width, height: bitmap.height)
            place(bitmap, at: placement)
        }

        mutating func decodeNonSymbolData() throws {
            guard started, mode == .image else {
                throw BookError.malformedDocument("DjVu JB2 non-symbol data is invalid in a dictionary")
            }
            let bitmapWidth = try number(.symbolWidth, 0...262_142)
            let bitmapHeight = try number(.symbolHeight, 0...262_142)
            let bitmap = try decodeDirectBitmap(width: bitmapWidth, height: bitmapHeight)
            let left = try number(.symbolColumn, 1...max(width, 1))
            let top = try number(.symbolRow, 1...max(height, 1))
            place(bitmap, at: Placement(left: left, top: top, width: bitmap.width, height: bitmap.height))
        }

        mutating func decodeComment() throws {
            let count = try number(.commentLength, 0...262_142)
            guard count <= maxOutputBytes else {
                throw BookError.malformedDocument("DjVu JB2 comment exceeds the configured limit")
            }
            for _ in 0..<count {
                _ = try number(.commentOctet, 0...255)
            }
        }

        mutating func decodeDirectBitmap(width: Int, height: Int) throws -> DjVuJB2Bitmap {
            try reserveSymbolPixels(width: width, height: height)
            var pixels = [UInt8](repeating: 0, count: width * height)
            let template = [
                (-1, -2), (0, -2), (1, -2),
                (-2, -1), (-1, -1), (0, -1), (1, -1), (2, -1),
                (-2, 0), (-1, 0),
            ]
            for y in 0..<height {
                for x in 0..<width {
                    var context = 0
                    for coordinate in template {
                        context = context * 2 + Int(pixel(
                            in: pixels,
                            width: width,
                            height: height,
                            x: x + coordinate.0,
                            y: y + coordinate.1
                        ))
                    }
                    var state = directContexts[context]
                    let value = try arithmetic.decode(state: &state)
                    directContexts[context] = state
                    pixels[y * width + x] = UInt8(value)
                }
            }
            return try DjVuJB2Bitmap(width: width, height: height, pixels: pixels)
        }

        mutating func decodeRefinedBitmap(
            width: Int,
            height: Int,
            matching: DjVuJB2Bitmap
        ) throws -> DjVuJB2Bitmap {
            try reserveSymbolPixels(width: width, height: height)
            var pixels = [UInt8](repeating: 0, count: width * height)
            let currentCenterX = (width - 1) / 2
            let currentCenterY = height / 2
            let matchingCenterX = (matching.width - 1) / 2
            let matchingCenterY = matching.height / 2

            for y in 0..<height {
                for x in 0..<width {
                    let matchingX = x - currentCenterX + matchingCenterX
                    let matchingY = y - currentCenterY + matchingCenterY
                    let currentTemplate = [(-1, -1), (0, -1), (1, -1), (-1, 0)]
                    let matchingTemplate = [
                        (0, -1), (-1, 0), (0, 0), (1, 0),
                        (-1, 1), (0, 1), (1, 1),
                    ]
                    var context = 0
                    for coordinate in currentTemplate {
                        context = context * 2 + Int(pixel(
                            in: pixels,
                            width: width,
                            height: height,
                            x: x + coordinate.0,
                            y: y + coordinate.1
                        ))
                    }
                    for coordinate in matchingTemplate {
                        context = context * 2 + Int(matching.pixel(
                            x: matchingX + coordinate.0,
                            y: matchingY + coordinate.1
                        ))
                    }
                    var state = refinementContexts[context]
                    let value = try arithmetic.decode(state: &state)
                    refinementContexts[context] = state
                    pixels[y * width + x] = UInt8(value)
                }
            }
            return try DjVuJB2Bitmap(width: width, height: height, pixels: pixels)
        }

        mutating func decodeRelativePlacement(width: Int, height: Int) throws -> Placement {
            let offsetType = try arithmetic.decode(state: &offsetTypeContext)
            let placement: Placement
            if offsetType == 1 || firstOnLine == nil || previousOnLine == nil {
                let referenceLeft = firstOnLine?.left ?? 0
                let referenceBottom = firstOnLine?.bottom ?? self.height
                let columnOffset = try number(.newLineColumnOffset, -262_143...262_142)
                let rowOffset = try number(.newLineRowOffset, -262_143...262_142)
                let left = referenceLeft + columnOffset
                let top = referenceBottom + rowOffset
                placement = Placement(left: left, top: top, width: width, height: height)
                firstOnLine = placement
                recentBottoms = [placement.bottom]
            } else {
                guard let previousOnLine, let firstOnLine else {
                    throw BookError.malformedDocument("DjVu JB2 relative placement has no reference")
                }
                let baseline: Int
                if recentBottoms.count >= 3 {
                    baseline = Array(recentBottoms.suffix(3)).sorted()[1]
                } else {
                    baseline = firstOnLine.bottom
                }
                let columnOffset = try number(.sameLineColumnOffset, -262_143...262_142)
                let rowOffset = try number(.sameLineRowOffset, -262_143...262_142)
                let left = previousOnLine.right + columnOffset
                let bottom = baseline + rowOffset
                placement = Placement(
                    left: left,
                    top: bottom + height - 1,
                    width: width,
                    height: height
                )
                recentBottoms.append(placement.bottom)
                if recentBottoms.count > 3 { recentBottoms.removeFirst() }
            }
            previousOnLine = placement
            return placement
        }

        mutating func place(_ bitmap: DjVuJB2Bitmap, at placement: Placement) {
            guard mode == .image else { return }
            let currentBlit = Int32(clamping: blitCount)
            blitCount += 1
            let destinationTop = height - placement.top
            for y in 0..<bitmap.height {
                let destinationY = destinationTop + y
                guard destinationY >= 0, destinationY < height else { continue }
                for x in 0..<bitmap.width where bitmap.pixels[y * bitmap.width + x] != 0 {
                    let destinationX = placement.left - 1 + x
                    guard destinationX >= 0, destinationX < width else { continue }
                    let destination = destinationY * width + destinationX
                    mask[destination] = 1
                    blitMap[destination] = currentBlit
                }
            }
        }

        mutating func appendSymbol(_ symbol: DjVuJB2Bitmap) throws {
            guard symbols.count < maxRecords else {
                throw BookError.malformedDocument("DjVu JB2 symbol library exceeds the configured limit")
            }
            symbols.append(symbol)
        }

        mutating func reserveSymbolPixels(width: Int, height: Int) throws {
            guard width >= 0, height >= 0,
                  width == 0 || height <= Int.max / max(width, 1)
            else {
                throw BookError.malformedDocument("DjVu JB2 symbol dimensions overflow")
            }
            let count = width * height
            guard count <= maxOutputBytes - min(decodedSymbolPixels, maxOutputBytes) else {
                throw BookError.malformedDocument("DjVu JB2 symbol data exceeds the configured limit")
            }
            decodedSymbolPixels += count
        }

        mutating func number(_ context: NumberContext, _ range: ClosedRange<Int>) throws -> Int {
            do {
                return try numbers[context.rawValue].decode(
                    lowerBound: range.lowerBound,
                    upperBound: range.upperBound,
                    arithmetic: &arithmetic
                )
            } catch {
                throw BookError.malformedDocument(
                    "DjVu JB2 \(context) field is invalid: \(error.localizedDescription)"
                )
            }
        }

        mutating func resetNumberContexts() {
            numbers = [IntegerContext](repeating: IntegerContext(), count: NumberContext.allCases.count)
        }

        func pixel(
            in pixels: [UInt8],
            width: Int,
            height: Int,
            x: Int,
            y: Int
        ) -> UInt8 {
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            return pixels[y * width + x]
        }
    }
}
