import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if canImport(ImageIO)
import ImageIO
#endif

struct DjVuRasterImage: Sendable, Equatable {
    let width: Int
    let height: Int
    /// Red, green, blue, alpha bytes in top-to-bottom row order.
    let rgba: [UInt8]

    init(width: Int, height: Int, rgba: [UInt8]) throws {
        guard width > 0, height > 0,
              width <= Int.max / height,
              width * height <= Int.max / 4,
              rgba.count == width * height * 4
        else {
            throw BookError.renderingFailed("DjVu raster dimensions are inconsistent")
        }
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    func pngData() throws -> Data {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else {
            throw BookError.renderingFailed("Unable to create the decoded DjVu image")
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw BookError.renderingFailed("Unable to create a DjVu PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw BookError.renderingFailed("Unable to encode the decoded DjVu image")
        }
        return output as Data
        #else
        throw BookError.renderingFailed("DjVu raster encoding requires CoreGraphics and ImageIO")
        #endif
    }
}

enum DjVuIW44Decoder {
    static func decode(chunks: [Data], maxOutputBytes: Int) throws -> DjVuRasterImage {
        guard !chunks.isEmpty else {
            throw BookError.malformedDocument("DjVu IW44 layer has no data chunks")
        }
        var state: State?

        for (expectedSerial, payload) in chunks.enumerated() {
            guard payload.count >= 2 else {
                throw BookError.malformedDocument("DjVu IW44 chunk header is truncated")
            }
            let serial = Int(payload[0])
            guard serial == expectedSerial, serial <= 255 else {
                throw BookError.malformedDocument(
                    "DjVu IW44 chunk serial number (serial) is out of sequence"
                )
            }
            let sliceCount = Int(payload[1])

            if serial == 0 {
                guard payload.count >= 9 else {
                    throw BookError.malformedDocument("DjVu IW44 initial header is truncated")
                }
                let versionAndColor = payload[2]
                let majorVersion = Int(versionAndColor & 0x7f)
                let minorVersion = Int(payload[3])
                guard majorVersion == 1, minorVersion <= 2 else {
                    throw BookError.renderingFailed(
                        "DjVu IW44 version (majorVersion).(minorVersion) is not supported"
                    )
                }
                let width = Int(payload[4]) << 8 | Int(payload[5])
                let height = Int(payload[6]) << 8 | Int(payload[7])
                let isGrayscale = versionAndColor & 0x80 != 0
                state = try State(
                    width: width,
                    height: height,
                    isGrayscale: isGrayscale,
                    chrominanceDelay: Int(payload[8] & 0x7f),
                    maxOutputBytes: maxOutputBytes
                )
            }

            guard var current = state else {
                throw BookError.malformedDocument("DjVu IW44 refinement precedes its initial chunk")
            }
            let headerLength = serial == 0 ? 9 : 2
            var arithmetic = DjVuZPDecoder(
                data: payload.subdata(in: headerLength..<payload.count),
                contextStates: current.contexts
            )
            try current.decodeSlices(sliceCount, arithmetic: &arithmetic)
            current.contexts = arithmetic.contextStates
            state = current
        }

        guard let state else {
            throw BookError.malformedDocument("DjVu IW44 layer could not be initialized")
        }
        return try state.reconstruct()
    }
}

private extension DjVuIW44Decoder {
    struct State {
        static let initialSteps = [
            0x04000, 0x08000, 0x08000, 0x10000,
            0x10000, 0x10000, 0x20000, 0x20000,
            0x20000, 0x40000, 0x40000, 0x40000,
            0x80000, 0x40000, 0x40000, 0x80000,
        ]

        static let bandBuckets: [Range<Int>] = [
            0..<1, 1..<2, 2..<3, 3..<4, 4..<8,
            8..<12, 12..<16, 16..<32, 32..<48, 48..<64,
        ]

        let width: Int
        let height: Int
        let isGrayscale: Bool
        let blocksWide: Int
        let blocksHigh: Int
        var chrominanceDelay: Int
        var bandNumbers: [Int]
        var steps: [[Int]]
        var coefficients: [[Int32]]
        var contexts: [UInt8]

        init(
            width: Int,
            height: Int,
            isGrayscale: Bool,
            chrominanceDelay: Int,
            maxOutputBytes: Int
        ) throws {
            guard width > 0, height > 0,
                  width <= Int.max / height,
                  width * height <= Int.max / 4,
                  width * height * 4 <= maxOutputBytes
            else {
                throw BookError.renderingFailed(
                    "DjVu IW44 image dimensions exceed the configured resource limit"
                )
            }
            self.width = width
            self.height = height
            self.isGrayscale = isGrayscale
            self.chrominanceDelay = chrominanceDelay
            blocksWide = (width + 31) / 32
            blocksHigh = (height + 31) / 32
            let componentCount = isGrayscale ? 1 : 3
            guard blocksWide <= Int.max / blocksHigh,
                  blocksWide * blocksHigh <= Int.max / 1024
            else {
                throw BookError.renderingFailed("DjVu IW44 coefficient dimensions overflow")
            }
            let coefficientCount = blocksWide * blocksHigh * 1024
            bandNumbers = [Int](repeating: 0, count: componentCount)
            steps = [[Int]](repeating: Self.initialSteps, count: componentCount)
            coefficients = [[Int32]](
                repeating: [Int32](repeating: 0, count: coefficientCount),
                count: componentCount
            )
            contexts = [UInt8](repeating: 0, count: componentCount * 98)
        }

        mutating func decodeSlices(
            _ count: Int,
            arithmetic: inout DjVuZPDecoder
        ) throws {
            for _ in 0..<count {
                try decodeBand(component: 0, arithmetic: &arithmetic)
                let includesChrominance = !isGrayscale && chrominanceDelay == 0
                if includesChrominance {
                    try decodeBand(component: 1, arithmetic: &arithmetic)
                    try decodeBand(component: 2, arithmetic: &arithmetic)
                }

                bandNumbers[0] = (bandNumbers[0] + 1) % 10
                if includesChrominance {
                    bandNumbers[1] = (bandNumbers[1] + 1) % 10
                    bandNumbers[2] = (bandNumbers[2] + 1) % 10
                } else if chrominanceDelay > 0 {
                    chrominanceDelay -= 1
                }
            }
        }

        mutating func decodeBand(
            component: Int,
            arithmetic: inout DjVuZPDecoder
        ) throws {
            let band = bandNumbers[component]
            let buckets = Self.bandBuckets[band]
            let contextBase = component * 98
            let blockCount = blocksWide * blocksHigh

            for block in 0..<blockCount {
                let coefficientBase = block * 1024
                try decodeBlockBand(
                    component: component,
                    coefficientBase: coefficientBase,
                    bucketRange: buckets,
                    band: band,
                    contextBase: contextBase,
                    arithmetic: &arithmetic
                )
            }

            let reductionRange = band == 0 ? 0...6 : (band + 6)...(band + 6)
            for stepIndex in reductionRange {
                let value = steps[component][stepIndex]
                steps[component][stepIndex] = value == 1 ? 0 : value / 2
            }
        }

        mutating func decodeBlockBand(
            component: Int,
            coefficientBase: Int,
            bucketRange: Range<Int>,
            band: Int,
            contextBase: Int,
            arithmetic: inout DjVuZPDecoder
        ) throws {
            let bucketCount = bucketRange.count
            var active = [Bool](repeating: false, count: bucketCount * 16)
            var potential = [Bool](repeating: false, count: bucketCount * 16)
            var bucketActive = [Bool](repeating: false, count: bucketCount)
            var bucketPotential = [Bool](repeating: false, count: bucketCount)

            for (relativeBucket, bucket) in bucketRange.enumerated() {
                for coefficientOffset in 0..<16 {
                    let relative = relativeBucket * 16 + coefficientOffset
                    let coefficientIndex = bucket * 16 + coefficientOffset
                    let step = steps[component][Self.stepIndex(for: coefficientIndex)]
                    guard step > 0, step < 0x8000 else { continue }
                    let value = coefficients[component][coefficientBase + coefficientIndex]
                    if value == 0 {
                        potential[relative] = true
                        bucketPotential[relativeBucket] = true
                    } else {
                        active[relative] = true
                        bucketActive[relativeBucket] = true
                    }
                }
            }

            let blockActive = bucketActive.contains(true)
            let blockPotential = bucketPotential.contains(true)
            var decodeBuckets = true
            if bucketCount == 16, !blockActive, blockPotential {
                decodeBuckets = try arithmetic.decode(context: contextBase) == 1
            }

            var decodeCoefficients = [Bool](repeating: false, count: bucketCount)
            if decodeBuckets {
                for (relativeBucket, bucket) in bucketRange.enumerated()
                    where bucketPotential[relativeBucket]
                {
                    let zeroContext: Int
                    if band == 0 {
                        zeroContext = 0
                    } else {
                        let start = coefficientBase + bucket * 4
                        let nonzeroCount = (0..<4).reduce(into: 0) { count, offset in
                            if coefficients[component][start + offset] != 0 { count += 1 }
                        }
                        zeroContext = min(nonzeroCount, 3)
                    }
                    let context = contextBase + 1 + band * 8 + (blockActive ? 4 : 0) + zeroContext
                    let decision = try arithmetic.decode(context: context) == 1
                    decodeCoefficients[relativeBucket] = decision
                }
            }

            if decodeBuckets {
                for (relativeBucket, bucket) in bucketRange.enumerated()
                    where decodeCoefficients[relativeBucket]
                {
                    var remainingPotential = potential[
                        (relativeBucket * 16)..<(relativeBucket * 16 + 16)
                    ].reduce(into: 0) { if $1 { $0 += 1 } }

                    for coefficientOffset in 0..<16 {
                        let relative = relativeBucket * 16 + coefficientOffset
                        guard potential[relative] else { continue }
                        let activationContext = contextBase + 81
                            + (bucketActive[relativeBucket] ? 8 : 0)
                            + min(remainingPotential, 7)
                        if try arithmetic.decode(context: activationContext) == 1 {
                            let coefficientIndex = bucket * 16 + coefficientOffset
                            let step = steps[component][Self.stepIndex(for: coefficientIndex)]
                            let magnitude = step + step / 2
                            let sign: Int32 = arithmetic.decodePassthrough() == 1 ? -1 : 1
                            coefficients[component][coefficientBase + coefficientIndex] = sign * Int32(magnitude)
                            remainingPotential = 0
                        }
                        if remainingPotential > 0 { remainingPotential -= 1 }
                    }
                }
            }

            // Only coefficients active before this block band was decoded are refined.
            for (relativeBucket, bucket) in bucketRange.enumerated() {
                for coefficientOffset in 0..<16 {
                    let relative = relativeBucket * 16 + coefficientOffset
                    guard active[relative] else { continue }
                    let coefficientIndex = bucket * 16 + coefficientOffset
                    let storageIndex = coefficientBase + coefficientIndex
                    let step = steps[component][Self.stepIndex(for: coefficientIndex)]
                    let oldValue = coefficients[component][storageIndex]
                    let oldMagnitude = abs(Int(oldValue))
                    let increase: Bool
                    if oldMagnitude <= 3 * step {
                        increase = try arithmetic.decode(context: contextBase + 97) == 1
                    } else {
                        increase = arithmetic.decodePassthrough() == 1
                    }
                    let adjustment = step == 1 ? (increase ? 0 : -1) : (increase ? step / 2 : -(step / 2))
                    let newMagnitude = max(oldMagnitude + adjustment, 0)
                    coefficients[component][storageIndex] = oldValue < 0
                        ? -Int32(newMagnitude)
                        : Int32(newMagnitude)
                }
            }
        }

        func reconstruct() throws -> DjVuRasterImage {
            var planes = [[Int32]]()
            planes.reserveCapacity(coefficients.count)
            for component in coefficients.indices {
                var plane = reorder(component: component)
                Self.inverseWavelet(&plane, width: width, height: height)
                planes.append(plane)
            }

            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for outputY in 0..<height {
                let sourceY = height - outputY - 1
                for x in 0..<width {
                    let source = sourceY * width + x
                    let destination = (outputY * width + x) * 4
                    if isGrayscale {
                        let value = Self.roundAndClamp(planes[0][source])
                        let gray = UInt8(127 - value)
                        rgba[destination] = gray
                        rgba[destination + 1] = gray
                        rgba[destination + 2] = gray
                    } else {
                        let y = Self.roundAndClamp(planes[0][source]) + 128
                        let cb = Self.roundAndClamp(planes[1][source])
                        let cr = Self.roundAndClamp(planes[2][source])
                        rgba[destination] = UInt8(clamping: y + Self.floorDivide(3 * cr, by: 2))
                        rgba[destination + 1] = UInt8(
                            clamping: y - Self.floorDivide(cb + 3 * cr, by: 4)
                        )
                        rgba[destination + 2] = UInt8(
                            clamping: y + Self.floorDivide(7 * cb, by: 4)
                        )
                    }
                }
            }
            return try DjVuRasterImage(width: width, height: height, rgba: rgba)
        }

        func reorder(component: Int) -> [Int32] {
            var output = [Int32](repeating: 0, count: width * height)
            for blockY in 0..<blocksHigh {
                for blockX in 0..<blocksWide {
                    let blockBase = (blockY * blocksWide + blockX) * 1024
                    for coefficientIndex in 0..<1024 {
                        let localX = Self.deinterleave(coefficientIndex, startingAtBit: 0)
                        let localY = Self.deinterleave(coefficientIndex, startingAtBit: 1)
                        let x = blockX * 32 + localX
                        let y = blockY * 32 + localY
                        guard x < width, y < height else { continue }
                        var value = coefficients[component][blockBase + coefficientIndex]
                        let step = steps[component][Self.stepIndex(for: coefficientIndex)]
                        // Deployed IW44 renderers bias a just-activated 3S
                        // coefficient one quarter-step toward zero. It reduces
                        // ringing while the next progressive bit is unknown.
                        if step >= 4, abs(Int(value)) == 3 * step {
                            let correction = Int32(step / 4)
                            value += value < 0 ? correction : -correction
                        }
                        output[y * width + x] = value
                    }
                }
            }
            return output
        }

        static func inverseWavelet(_ values: inout [Int32], width: Int, height: Int) {
            var scale = 16
            while scale >= 1 {
                var x = 0
                while x < width {
                    transformLine(&values, start: x, stride: width * scale, count: (height - 1) / scale + 1)
                    x += scale
                }
                var y = 0
                while y < height {
                    transformLine(&values, start: y * width, stride: scale, count: (width - 1) / scale + 1)
                    y += scale
                }
                scale /= 2
            }
        }

        static func transformLine(
            _ values: inout [Int32],
            start: Int,
            stride: Int,
            count: Int
        ) {
            guard count > 1 else { return }
            var k = 0
            while k < count {
                let previous3 = k >= 3 ? Int(values[start + (k - 3) * stride]) : 0
                let previous1 = k >= 1 ? Int(values[start + (k - 1) * stride]) : 0
                let next1 = k + 1 < count ? Int(values[start + (k + 1) * stride]) : 0
                let next3 = k + 3 < count ? Int(values[start + (k + 3) * stride]) : 0
                let prediction = floorDivide(
                    9 * (previous1 + next1) - (previous3 + next3) + 16,
                    by: 32
                )
                values[start + k * stride] -= Int32(prediction)
                k += 2
            }

            k = 1
            while k < count {
                let index = start + k * stride
                if k >= 3, k + 3 < count {
                    let previous3 = Int(values[start + (k - 3) * stride])
                    let previous1 = Int(values[start + (k - 1) * stride])
                    let next1 = Int(values[start + (k + 1) * stride])
                    let next3 = Int(values[start + (k + 3) * stride])
                    let prediction = floorDivide(
                        9 * (previous1 + next1) - (previous3 + next3) + 8,
                        by: 16
                    )
                    values[index] += Int32(prediction)
                } else if k + 1 < count {
                    let previous = Int(values[start + (k - 1) * stride])
                    let next = Int(values[start + (k + 1) * stride])
                    values[index] += Int32(floorDivide(previous + next + 1, by: 2))
                } else {
                    values[index] += values[start + (k - 1) * stride]
                }
                k += 2
            }
        }

        static func roundAndClamp(_ value: Int32) -> Int {
            min(max(floorDivide(Int(value) + 32, by: 64), -128), 127)
        }

        static func floorDivide(_ numerator: Int, by denominator: Int) -> Int {
            let quotient = numerator / denominator
            let remainder = numerator % denominator
            return remainder < 0 ? quotient - 1 : quotient
        }

        static func stepIndex(for coefficientIndex: Int) -> Int {
            switch coefficientIndex {
            case 0: 0
            case 1: 1
            case 2: 2
            case 3: 3
            case 4..<8: 4
            case 8..<12: 5
            case 12..<16: 6
            case 16..<32: 7
            case 32..<48: 8
            case 48..<64: 9
            case 64..<128: 10
            case 128..<192: 11
            case 192..<256: 12
            case 256..<512: 13
            case 512..<768: 14
            default: 15
            }
        }

        static func deinterleave(_ value: Int, startingAtBit bit: Int) -> Int {
            var result = 0
            for destinationBit in 0..<5 {
                let sourceBit = bit + destinationBit * 2
                result |= ((value >> sourceBit) & 1) << (4 - destinationBit)
            }
            return result
        }
    }
}
