import Foundation

enum DjVuBZZDecoder {
    static func decode(_ data: Data, maxOutputBytes: Int) throws -> Data {
        guard maxOutputBytes >= 0 else {
            throw BookError.invalidContainer("DjVu BZZ output limit is invalid")
        }
        var decoder = DjVuZPDecoder(data: data, contextCount: 262)
        var output = Data()

        while true {
            let blockSize = decoder.decodeRaw(bitCount: 24)
            if blockSize == 0 { return output }
            guard blockSize > 1, blockSize <= 4 * 1024 * 1024 else {
                throw BookError.invalidContainer("DjVu BZZ block size is outside the specified range")
            }
            let decodedCount = blockSize - 1
            guard decodedCount <= maxOutputBytes - output.count else {
                throw BookError.invalidContainer("DjVu BZZ output exceeds the configured limit")
            }
            output.append(try decodeBlock(size: blockSize, decoder: &decoder))
        }
    }

    private static func decodeBlock(
        size blockSize: Int,
        decoder: inout DjVuZPDecoder
    ) throws -> Data {
        var fshift = 0
        if decoder.decodePassthrough() == 1 {
            fshift = decoder.decodePassthrough() == 1 ? 2 : 1
        }

        var moveToFront = (0...255).map(UInt8.init)
        var data = [UInt8](repeating: 0, count: blockSize)
        var previousIndex = 3
        var markerPosition: Int?
        var frequencyAddition = 4
        var frequencies = [Int](repeating: 0, count: 4)

        for index in data.indices {
            let contextID = previousIndex <= 2 ? previousIndex : 2
            let moveToFrontIndex: Int
            if try decoder.decode(context: contextID) == 1 {
                moveToFrontIndex = 0
            } else if try decoder.decode(context: contextID + 3) == 1 {
                moveToFrontIndex = 1
            } else if try decoder.decode(context: 6) == 1 {
                moveToFrontIndex = 2 + (try decoder.decodeBinary(contextOffset: 7, bitCount: 1))
            } else if try decoder.decode(context: 8) == 1 {
                moveToFrontIndex = 4 + (try decoder.decodeBinary(contextOffset: 9, bitCount: 2))
            } else if try decoder.decode(context: 12) == 1 {
                moveToFrontIndex = 8 + (try decoder.decodeBinary(contextOffset: 13, bitCount: 3))
            } else if try decoder.decode(context: 20) == 1 {
                moveToFrontIndex = 16 + (try decoder.decodeBinary(contextOffset: 21, bitCount: 4))
            } else if try decoder.decode(context: 36) == 1 {
                moveToFrontIndex = 32 + (try decoder.decodeBinary(contextOffset: 37, bitCount: 5))
            } else if try decoder.decode(context: 68) == 1 {
                moveToFrontIndex = 64 + (try decoder.decodeBinary(contextOffset: 69, bitCount: 6))
            } else if try decoder.decode(context: 132) == 1 {
                moveToFrontIndex = 128 + (try decoder.decodeBinary(contextOffset: 133, bitCount: 7))
            } else {
                moveToFrontIndex = 256
            }

            previousIndex = moveToFrontIndex
            if moveToFrontIndex == 256 {
                guard markerPosition == nil else {
                    throw BookError.invalidContainer("DjVu BZZ block contains multiple end markers")
                }
                data[index] = 0
                markerPosition = index
                continue
            }

            guard moveToFront.indices.contains(moveToFrontIndex) else {
                throw BookError.invalidContainer("DjVu BZZ move-to-front index is invalid")
            }
            let symbol = moveToFront[moveToFrontIndex]
            data[index] = symbol

            frequencyAddition += frequencyAddition >> fshift
            if frequencyAddition > 0x10000000 {
                frequencyAddition >>= 24
                for frequencyIndex in frequencies.indices {
                    frequencies[frequencyIndex] >>= 24
                }
            }
            let newFrequency = frequencyAddition + (
                moveToFrontIndex < 4 ? frequencies[moveToFrontIndex] : 0
            )

            var targetIndex = moveToFrontIndex
            while targetIndex > 3 {
                moveToFront[targetIndex] = moveToFront[targetIndex - 1]
                targetIndex -= 1
            }
            while targetIndex > 0, newFrequency >= frequencies[targetIndex - 1] {
                moveToFront[targetIndex] = moveToFront[targetIndex - 1]
                frequencies[targetIndex] = frequencies[targetIndex - 1]
                targetIndex -= 1
            }
            moveToFront[targetIndex] = symbol
            frequencies[targetIndex] = newFrequency
        }

        guard let markerPosition, markerPosition > 0, markerPosition < blockSize else {
            throw BookError.invalidContainer(
                "DjVu BZZ block of \(blockSize) bytes has no valid end marker"
            )
        }
        return try inverseBurrowsWheeler(data, markerPosition: markerPosition)
    }

    private static func inverseBurrowsWheeler(
        _ source: [UInt8],
        markerPosition: Int
    ) throws -> Data {
        let blockSize = source.count
        var occurrenceCounts = [Int](repeating: 0, count: 256)
        var occurrenceRanks = [Int](repeating: 0, count: blockSize)

        for index in source.indices {
            let symbol = Int(source[index])
            if index == markerPosition {
                occurrenceRanks[index] = 0
            } else {
                occurrenceRanks[index] = occurrenceCounts[symbol]
                occurrenceCounts[symbol] += 1
            }
        }

        var nextRunStart = 1
        for symbol in occurrenceCounts.indices {
            let count = occurrenceCounts[symbol]
            occurrenceCounts[symbol] = nextRunStart
            nextRunStart += count
        }
        guard nextRunStart == blockSize else {
            throw BookError.invalidContainer("DjVu BZZ symbol counts are inconsistent")
        }

        var output = [UInt8](repeating: 0, count: blockSize - 1)
        var sourceIndex = 0
        var outputIndex = blockSize - 1
        while outputIndex > 0 {
            outputIndex -= 1
            guard source.indices.contains(sourceIndex) else {
                throw BookError.invalidContainer("DjVu BZZ transform index is invalid")
            }
            let symbol = source[sourceIndex]
            output[outputIndex] = symbol
            sourceIndex = occurrenceCounts[Int(symbol)] + occurrenceRanks[sourceIndex]
        }
        guard sourceIndex == markerPosition else {
            throw BookError.invalidContainer("DjVu BZZ end marker is inconsistent")
        }
        return Data(output)
    }
}
