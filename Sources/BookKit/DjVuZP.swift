import Foundation

struct DjVuZPDecoder {
    private var bytes: [UInt8]
    private var byteIndex = 2
    private var bitMask: UInt8 = 0x80
    private var a = 0
    private var c: Int
    private var contexts: [UInt8]

    init(data: Data, contextCount: Int) {
        self.init(data: data, contextStates: [UInt8](repeating: 0, count: max(contextCount, 0)))
    }

    init(data: Data, contextStates: [UInt8]) {
        bytes = Array(data)
        let first = bytes.indices.contains(0) ? Int(bytes[0]) : 0xff
        let second = bytes.indices.contains(1) ? Int(bytes[1]) : 0xff
        c = first << 8 | second
        contexts = contextStates
    }

    var contextStates: [UInt8] { contexts }
    var hasExhaustedInput: Bool { byteIndex >= bytes.count }

    mutating func decode(context index: Int) throws -> Int {
        guard contexts.indices.contains(index) else {
            throw BookError.invalidContainer("DjVu Z-prime context index is out of bounds")
        }
        var contextState = contexts[index]
        let bit = try decode(state: &contextState)
        contexts[index] = contextState
        return bit
    }

    mutating func decode(state contextState: inout UInt8) throws -> Int {
        let stateIndex = Int(contextState)
        guard Self.states.indices.contains(stateIndex) else {
            throw BookError.invalidContainer("DjVu Z-prime probability state is invalid")
        }
        let state = Self.states[stateIndex]
        var z = a + Int(state.delta)

        // DjVu compatibility streams use the coder's MPS fast path. Besides
        // avoiding normalization, this deliberately leaves the probability
        // state unchanged until the interval crosses the 0x7fff fence.
        if z <= min(c, 0x7fff) {
            a = z
            return stateIndex & 1
        }

        let d = 0x6000 + ((z + a) >> 2)
        if z > d { z = d }

        let bit: Int
        if c >= z {
            bit = stateIndex & 1
            if a >= Int(state.threshold) {
                contextState = state.mpsNext
            }
            a = z
        } else {
            bit = 1 - (stateIndex & 1)
            a = (a + 0x10000 - z) & 0xffff
            c = (c + 0x10000 - z) & 0xffff
            contextState = state.lpsNext
        }
        normalize()
        return bit
    }

    mutating func decodePassthrough() -> Int {
        let z = 0x8000 + ((a + a + a) >> 3)
        let bit: Int
        if c >= z {
            bit = 0
            a = z
        } else {
            bit = 1
            a = (a + 0x10000 - z) & 0xffff
            c = (c + 0x10000 - z) & 0xffff
        }
        normalize()
        return bit
    }


    mutating func decodeRaw(bitCount: Int) -> Int {
        guard bitCount > 0 else { return 0 }
        let terminal = 1 << bitCount
        var value = 1
        while value < terminal {
            value = value * 2 + decodePassthrough()
        }
        return value - terminal
    }

    mutating func decodeBinary(contextOffset: Int, bitCount: Int) throws -> Int {
        guard bitCount > 0 else { return 0 }
        let terminal = 1 << bitCount
        var value = 1
        while value < terminal {
            value = value * 2 + (try decode(context: contextOffset + value - 1))
        }
        return value - terminal
    }

    private mutating func normalize() {
        while a >= 0x8000 {
            a = (a << 1) & 0xffff
            c = ((c << 1) & 0xffff) | nextBit()
        }
    }

    private mutating func nextBit() -> Int {
        guard bytes.indices.contains(byteIndex) else { return 1 }
        let value = bytes[byteIndex] & bitMask == 0 ? 0 : 1
        bitMask >>= 1
        if bitMask == 0 {
            bitMask = 0x80
            byteIndex += 1
        }
        return value
    }
}

private extension DjVuZPDecoder {
    struct State: Sendable {
        var delta: UInt16
        var threshold: UInt16
        var mpsNext: UInt8
        var lpsNext: UInt8
    }

    static let states: [State] = {
        var result: [State] = [
            State(delta: 0x8000, threshold: 0, mpsNext: 84, lpsNext: 145),
            State(delta: 0x8000, threshold: 0, mpsNext: 3, lpsNext: 4),
            State(delta: 0x8000, threshold: 0, mpsNext: 4, lpsNext: 3),
        ]
        let steadyPairs: [(UInt16, UInt16)] = [
            (0x6BBD, 0x10A5), (0x5D45, 0x1F28), (0x51B9, 0x2BD3),
            (0x4813, 0x36E3), (0x3FD5, 0x408C), (0x38B1, 0x48FD),
            (0x3275, 0x505D), (0x2CFD, 0x56D0), (0x2825, 0x5C71),
            (0x23AB, 0x615B), (0x1F87, 0x65A5), (0x1BBB, 0x6962),
            (0x1845, 0x6CA2), (0x1523, 0x6F74), (0x1253, 0x71E6),
            (0x0FCF, 0x7404), (0x0D95, 0x75D6), (0x0B9D, 0x7768),
            (0x09E3, 0x78C2), (0x0861, 0x79EA), (0x0711, 0x7AE7),
            (0x05F1, 0x7BBE), (0x04F9, 0x7C75), (0x0425, 0x7D0F),
            (0x0371, 0x7D91), (0x02D9, 0x7DFE), (0x0259, 0x7E5A),
            (0x01ED, 0x7EA6), (0x0193, 0x7EE6), (0x0149, 0x7F1A),
            (0x010B, 0x7F45), (0x00D5, 0x7F6B), (0x00A5, 0x7F8D),
            (0x007B, 0x7FAA), (0x0057, 0x7FC3), (0x003B, 0x7FD7),
            (0x0023, 0x7FE7), (0x0013, 0x7FF2), (0x0007, 0x7FFA),
        ]
        for (pairIndex, pair) in steadyPairs.enumerated() {
            let odd = 3 + pairIndex * 2
            result.append(
                State(
                    delta: pair.0,
                    threshold: pair.1,
                    mpsNext: UInt8(odd + 2),
                    lpsNext: UInt8(odd - 2)
                )
            )
            result.append(
                State(
                    delta: pair.0,
                    threshold: pair.1,
                    mpsNext: UInt8(odd + 3),
                    lpsNext: UInt8(odd - 1)
                )
            )
        }
        result.append(State(delta: 0x0001, threshold: 0x7FFF, mpsNext: 81, lpsNext: 79))
        result.append(State(delta: 0x0001, threshold: 0x7FFF, mpsNext: 82, lpsNext: 80))

        // Early-estimation states 83...250, transcribed from Table 9 of the DjVu v3 spec.
        result.append(contentsOf: [
            State(delta: 0x5695, threshold: 0, mpsNext: 9, lpsNext: 85),
            State(delta: 0x24EE, threshold: 0, mpsNext: 86, lpsNext: 226),
            State(delta: 0x8000, threshold: 0, mpsNext: 5, lpsNext: 6),
            State(delta: 0x0D30, threshold: 0, mpsNext: 88, lpsNext: 176),
            State(delta: 0x481A, threshold: 0, mpsNext: 89, lpsNext: 143),
            State(delta: 0x0481, threshold: 0, mpsNext: 90, lpsNext: 138),
            State(delta: 0x3579, threshold: 0, mpsNext: 91, lpsNext: 141),
            State(delta: 0x017A, threshold: 0, mpsNext: 92, lpsNext: 112),
            State(delta: 0x24EF, threshold: 0, mpsNext: 93, lpsNext: 135),
            State(delta: 0x007B, threshold: 0, mpsNext: 94, lpsNext: 104),
            State(delta: 0x1978, threshold: 0, mpsNext: 95, lpsNext: 133),
            State(delta: 0x0028, threshold: 0, mpsNext: 96, lpsNext: 100),
            State(delta: 0x10CA, threshold: 0, mpsNext: 97, lpsNext: 129),
            State(delta: 0x000D, threshold: 0, mpsNext: 82, lpsNext: 98),
            State(delta: 0x0B5D, threshold: 0, mpsNext: 99, lpsNext: 127),
            State(delta: 0x0034, threshold: 0, mpsNext: 76, lpsNext: 72),
            State(delta: 0x078A, threshold: 0, mpsNext: 101, lpsNext: 125),
            State(delta: 0x00A0, threshold: 0, mpsNext: 70, lpsNext: 102),
            State(delta: 0x050F, threshold: 0, mpsNext: 103, lpsNext: 123),
            State(delta: 0x0117, threshold: 0, mpsNext: 66, lpsNext: 60),
            State(delta: 0x0358, threshold: 0, mpsNext: 105, lpsNext: 121),
            State(delta: 0x01EA, threshold: 0, mpsNext: 106, lpsNext: 110),
            State(delta: 0x0234, threshold: 0, mpsNext: 107, lpsNext: 119),
            State(delta: 0x0144, threshold: 0, mpsNext: 66, lpsNext: 108),
            State(delta: 0x0173, threshold: 0, mpsNext: 109, lpsNext: 117),
            State(delta: 0x0234, threshold: 0, mpsNext: 60, lpsNext: 54),
            State(delta: 0x00F5, threshold: 0, mpsNext: 111, lpsNext: 115),
            State(delta: 0x0353, threshold: 0, mpsNext: 56, lpsNext: 48),
            State(delta: 0x00A1, threshold: 0, mpsNext: 69, lpsNext: 113),
            State(delta: 0x05C5, threshold: 0, mpsNext: 114, lpsNext: 134),
            State(delta: 0x011A, threshold: 0, mpsNext: 65, lpsNext: 59),
            State(delta: 0x03CF, threshold: 0, mpsNext: 116, lpsNext: 132),
            State(delta: 0x01AA, threshold: 0, mpsNext: 61, lpsNext: 55),
            State(delta: 0x0285, threshold: 0, mpsNext: 118, lpsNext: 130),
            State(delta: 0x0286, threshold: 0, mpsNext: 57, lpsNext: 51),
            State(delta: 0x01AB, threshold: 0, mpsNext: 120, lpsNext: 128),
            State(delta: 0x03D3, threshold: 0, mpsNext: 53, lpsNext: 47),
            State(delta: 0x011A, threshold: 0, mpsNext: 122, lpsNext: 126),
            State(delta: 0x05C5, threshold: 0, mpsNext: 49, lpsNext: 41),
            State(delta: 0x00BA, threshold: 0, mpsNext: 124, lpsNext: 62),
            State(delta: 0x08AD, threshold: 0, mpsNext: 43, lpsNext: 37),
            State(delta: 0x007A, threshold: 0, mpsNext: 72, lpsNext: 66),
            State(delta: 0x0CCC, threshold: 0, mpsNext: 39, lpsNext: 31),
            State(delta: 0x01EB, threshold: 0, mpsNext: 60, lpsNext: 54),
            State(delta: 0x1302, threshold: 0, mpsNext: 33, lpsNext: 25),
            State(delta: 0x02E6, threshold: 0, mpsNext: 56, lpsNext: 50),
            State(delta: 0x1B81, threshold: 0, mpsNext: 29, lpsNext: 131),
            State(delta: 0x045E, threshold: 0, mpsNext: 52, lpsNext: 46),
            State(delta: 0x24EF, threshold: 0, mpsNext: 23, lpsNext: 17),
            State(delta: 0x0690, threshold: 0, mpsNext: 48, lpsNext: 40),
            State(delta: 0x2865, threshold: 0, mpsNext: 23, lpsNext: 15),
            State(delta: 0x09DE, threshold: 0, mpsNext: 42, lpsNext: 136),
            State(delta: 0x3987, threshold: 0, mpsNext: 137, lpsNext: 7),
            State(delta: 0x0DC8, threshold: 0, mpsNext: 38, lpsNext: 32),
            State(delta: 0x2C99, threshold: 0, mpsNext: 21, lpsNext: 139),
            State(delta: 0x10CA, threshold: 0, mpsNext: 140, lpsNext: 172),
            State(delta: 0x3B5F, threshold: 0, mpsNext: 15, lpsNext: 9),
            State(delta: 0x0B5D, threshold: 0, mpsNext: 142, lpsNext: 170),
            State(delta: 0x5695, threshold: 0, mpsNext: 9, lpsNext: 85),
            State(delta: 0x078A, threshold: 0, mpsNext: 144, lpsNext: 168),
            State(delta: 0x8000, threshold: 0, mpsNext: 141, lpsNext: 248),
            State(delta: 0x050F, threshold: 0, mpsNext: 146, lpsNext: 166),
            State(delta: 0x24EE, threshold: 0, mpsNext: 147, lpsNext: 247),
            State(delta: 0x0358, threshold: 0, mpsNext: 148, lpsNext: 164),
            State(delta: 0x0D30, threshold: 0, mpsNext: 149, lpsNext: 197),
            State(delta: 0x0234, threshold: 0, mpsNext: 150, lpsNext: 162),
            State(delta: 0x0481, threshold: 0, mpsNext: 151, lpsNext: 95),
            State(delta: 0x0173, threshold: 0, mpsNext: 152, lpsNext: 160),
            State(delta: 0x017A, threshold: 0, mpsNext: 153, lpsNext: 173),
            State(delta: 0x00F5, threshold: 0, mpsNext: 154, lpsNext: 158),
            State(delta: 0x007B, threshold: 0, mpsNext: 155, lpsNext: 165),
            State(delta: 0x00A1, threshold: 0, mpsNext: 70, lpsNext: 156),
            State(delta: 0x0028, threshold: 0, mpsNext: 157, lpsNext: 161),
            State(delta: 0x011A, threshold: 0, mpsNext: 66, lpsNext: 60),
            State(delta: 0x000D, threshold: 0, mpsNext: 81, lpsNext: 159),
            State(delta: 0x01AA, threshold: 0, mpsNext: 62, lpsNext: 56),
            State(delta: 0x0034, threshold: 0, mpsNext: 75, lpsNext: 71),
            State(delta: 0x0286, threshold: 0, mpsNext: 58, lpsNext: 52),
            State(delta: 0x00A0, threshold: 0, mpsNext: 69, lpsNext: 163),
            State(delta: 0x03D3, threshold: 0, mpsNext: 54, lpsNext: 48),
            State(delta: 0x0117, threshold: 0, mpsNext: 65, lpsNext: 59),
            State(delta: 0x05C5, threshold: 0, mpsNext: 50, lpsNext: 42),
            State(delta: 0x01EA, threshold: 0, mpsNext: 167, lpsNext: 171),
            State(delta: 0x08AD, threshold: 0, mpsNext: 44, lpsNext: 38),
            State(delta: 0x0144, threshold: 0, mpsNext: 65, lpsNext: 169),
            State(delta: 0x0CCC, threshold: 0, mpsNext: 40, lpsNext: 32),
            State(delta: 0x0234, threshold: 0, mpsNext: 59, lpsNext: 53),
            State(delta: 0x1302, threshold: 0, mpsNext: 34, lpsNext: 26),
            State(delta: 0x0353, threshold: 0, mpsNext: 55, lpsNext: 47),
            State(delta: 0x1B81, threshold: 0, mpsNext: 30, lpsNext: 174),
            State(delta: 0x05C5, threshold: 0, mpsNext: 175, lpsNext: 193),
            State(delta: 0x24EF, threshold: 0, mpsNext: 24, lpsNext: 18),
            State(delta: 0x03CF, threshold: 0, mpsNext: 177, lpsNext: 191),
            State(delta: 0x2B74, threshold: 0, mpsNext: 178, lpsNext: 222),
            State(delta: 0x0285, threshold: 0, mpsNext: 179, lpsNext: 189),
            State(delta: 0x201D, threshold: 0, mpsNext: 180, lpsNext: 218),
            State(delta: 0x01AB, threshold: 0, mpsNext: 181, lpsNext: 187),
            State(delta: 0x1715, threshold: 0, mpsNext: 182, lpsNext: 216),
            State(delta: 0x011A, threshold: 0, mpsNext: 183, lpsNext: 185),
            State(delta: 0x0FB7, threshold: 0, mpsNext: 184, lpsNext: 214),
            State(delta: 0x00BA, threshold: 0, mpsNext: 69, lpsNext: 61),
            State(delta: 0x0A67, threshold: 0, mpsNext: 186, lpsNext: 212),
            State(delta: 0x01EB, threshold: 0, mpsNext: 59, lpsNext: 53),
            State(delta: 0x06E7, threshold: 0, mpsNext: 188, lpsNext: 210),
            State(delta: 0x02E6, threshold: 0, mpsNext: 55, lpsNext: 49),
            State(delta: 0x0496, threshold: 0, mpsNext: 190, lpsNext: 208),
            State(delta: 0x045E, threshold: 0, mpsNext: 51, lpsNext: 45),
            State(delta: 0x030D, threshold: 0, mpsNext: 192, lpsNext: 206),
            State(delta: 0x0690, threshold: 0, mpsNext: 47, lpsNext: 39),
            State(delta: 0x0206, threshold: 0, mpsNext: 194, lpsNext: 204),
            State(delta: 0x09DE, threshold: 0, mpsNext: 41, lpsNext: 195),
            State(delta: 0x0155, threshold: 0, mpsNext: 196, lpsNext: 202),
            State(delta: 0x0DC8, threshold: 0, mpsNext: 37, lpsNext: 31),
            State(delta: 0x00E1, threshold: 0, mpsNext: 198, lpsNext: 200),
            State(delta: 0x2B74, threshold: 0, mpsNext: 199, lpsNext: 243),
            State(delta: 0x0094, threshold: 0, mpsNext: 72, lpsNext: 64),
            State(delta: 0x201D, threshold: 0, mpsNext: 201, lpsNext: 239),
            State(delta: 0x0188, threshold: 0, mpsNext: 62, lpsNext: 56),
            State(delta: 0x1715, threshold: 0, mpsNext: 203, lpsNext: 237),
            State(delta: 0x0252, threshold: 0, mpsNext: 58, lpsNext: 52),
            State(delta: 0x0FB7, threshold: 0, mpsNext: 205, lpsNext: 235),
            State(delta: 0x0383, threshold: 0, mpsNext: 54, lpsNext: 48),
            State(delta: 0x0A67, threshold: 0, mpsNext: 207, lpsNext: 233),
            State(delta: 0x0547, threshold: 0, mpsNext: 50, lpsNext: 44),
            State(delta: 0x06E7, threshold: 0, mpsNext: 209, lpsNext: 231),
            State(delta: 0x07E2, threshold: 0, mpsNext: 46, lpsNext: 38),
            State(delta: 0x0496, threshold: 0, mpsNext: 211, lpsNext: 229),
            State(delta: 0x0BC0, threshold: 0, mpsNext: 40, lpsNext: 34),
            State(delta: 0x030D, threshold: 0, mpsNext: 213, lpsNext: 227),
            State(delta: 0x1178, threshold: 0, mpsNext: 36, lpsNext: 28),
            State(delta: 0x0206, threshold: 0, mpsNext: 215, lpsNext: 225),
            State(delta: 0x19DA, threshold: 0, mpsNext: 30, lpsNext: 22),
            State(delta: 0x0155, threshold: 0, mpsNext: 217, lpsNext: 223),
            State(delta: 0x24EF, threshold: 0, mpsNext: 26, lpsNext: 16),
            State(delta: 0x00E1, threshold: 0, mpsNext: 219, lpsNext: 221),
            State(delta: 0x320E, threshold: 0, mpsNext: 20, lpsNext: 220),
            State(delta: 0x0094, threshold: 0, mpsNext: 71, lpsNext: 63),
            State(delta: 0x432A, threshold: 0, mpsNext: 14, lpsNext: 8),
            State(delta: 0x0188, threshold: 0, mpsNext: 61, lpsNext: 55),
            State(delta: 0x447D, threshold: 0, mpsNext: 14, lpsNext: 224),
            State(delta: 0x0252, threshold: 0, mpsNext: 57, lpsNext: 51),
            State(delta: 0x5ECE, threshold: 0, mpsNext: 8, lpsNext: 2),
            State(delta: 0x0383, threshold: 0, mpsNext: 53, lpsNext: 47),
            State(delta: 0x8000, threshold: 0, mpsNext: 228, lpsNext: 87),
            State(delta: 0x0547, threshold: 0, mpsNext: 49, lpsNext: 43),
            State(delta: 0x481A, threshold: 0, mpsNext: 230, lpsNext: 246),
            State(delta: 0x07E2, threshold: 0, mpsNext: 45, lpsNext: 37),
            State(delta: 0x3579, threshold: 0, mpsNext: 232, lpsNext: 244),
            State(delta: 0x0BC0, threshold: 0, mpsNext: 39, lpsNext: 33),
            State(delta: 0x24EF, threshold: 0, mpsNext: 234, lpsNext: 238),
            State(delta: 0x1178, threshold: 0, mpsNext: 35, lpsNext: 27),
            State(delta: 0x1978, threshold: 0, mpsNext: 138, lpsNext: 236),
            State(delta: 0x19DA, threshold: 0, mpsNext: 29, lpsNext: 21),
            State(delta: 0x2865, threshold: 0, mpsNext: 24, lpsNext: 16),
            State(delta: 0x24EF, threshold: 0, mpsNext: 25, lpsNext: 15),
            State(delta: 0x3987, threshold: 0, mpsNext: 240, lpsNext: 8),
            State(delta: 0x320E, threshold: 0, mpsNext: 19, lpsNext: 241),
            State(delta: 0x2C99, threshold: 0, mpsNext: 22, lpsNext: 242),
            State(delta: 0x432A, threshold: 0, mpsNext: 13, lpsNext: 7),
            State(delta: 0x3B5F, threshold: 0, mpsNext: 16, lpsNext: 10),
            State(delta: 0x447D, threshold: 0, mpsNext: 13, lpsNext: 245),
            State(delta: 0x5695, threshold: 0, mpsNext: 10, lpsNext: 2),
            State(delta: 0x5ECE, threshold: 0, mpsNext: 7, lpsNext: 1),
            State(delta: 0x8000, threshold: 0, mpsNext: 244, lpsNext: 83),
            State(delta: 0x8000, threshold: 0, mpsNext: 249, lpsNext: 250),
            State(delta: 0x5695, threshold: 0, mpsNext: 10, lpsNext: 2),
            State(delta: 0x481A, threshold: 0, mpsNext: 89, lpsNext: 143),
            State(delta: 0x481A, threshold: 0, mpsNext: 230, lpsNext: 246),
        ])
        precondition(result.count == 251)
        return result
    }()
}
