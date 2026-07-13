import Foundation

enum DjVuRotation: Int, Sendable, Equatable, Hashable, Codable {
    case upright = 1
    case counterClockwise90 = 6
    case upsideDown = 2
    case clockwise90 = 5
}

struct DjVuPageInfo: Sendable, Equatable, Hashable, Codable {
    public var width: Int
    public var height: Int
    public var minorVersion: Int
    public var majorVersion: Int
    public var dpi: Int
    public var gamma: Double
    public var rotation: DjVuRotation

    public init(
        width: Int,
        height: Int,
        minorVersion: Int,
        majorVersion: Int,
        dpi: Int,
        gamma: Double,
        rotation: DjVuRotation
    ) {
        self.width = width
        self.height = height
        self.minorVersion = minorVersion
        self.majorVersion = majorVersion
        self.dpi = dpi
        self.gamma = gamma
        self.rotation = rotation
    }
}

struct DjVuIFFChunk: Sendable, Equatable {
    let id: String
    let formType: String?
    let headerOffset: Int
    let payloadRange: Range<Int>
    let children: [DjVuIFFChunk]

    func payload(in data: Data) -> Data {
        data.subdata(in: payloadRange)
    }
}

struct DjVuIFFPage: Sendable, Equatable {
    let formOffset: Int
    let info: DjVuPageInfo
    let chunks: [DjVuIFFChunk]
}

struct DjVuIFFDocument: Sendable, Equatable {
    let formType: String
    let root: DjVuIFFChunk
    let pages: [DjVuIFFPage]
}

enum DjVuIFFParser {
    static func parse(_ data: Data, options: OpenOptions) throws -> DjVuIFFDocument {
        guard data.count >= 16, data.prefix(4) == Data("AT&T".utf8) else {
            throw BookError.invalidContainer("DjVu header is missing")
        }

        var state = State(data: data, maxChunkCount: options.maxArchiveEntries)
        let parsed = try state.parseChunk(
            at: 4,
            limit: data.count,
            depth: 0,
            allowMissingTerminalPadding: true
        )
        guard parsed.chunk.id == "FORM", let formType = parsed.chunk.formType else {
            throw BookError.invalidContainer("DjVu outer chunk must be FORM")
        }
        guard parsed.paddedEnd == data.count else {
            throw BookError.invalidContainer("Trailing or truncated data follows the DjVu FORM chunk")
        }

        let pageForms: [DjVuIFFChunk]
        switch formType {
        case "DJVU":
            pageForms = [parsed.chunk]
        case "DJVM":
            guard parsed.chunk.children.first?.id == "DIRM" else {
                throw BookError.malformedDocument("FORM:DJVM must begin with a DIRM chunk")
            }
            pageForms = parsed.chunk.children.filter {
                $0.id == "FORM" && $0.formType == "DJVU"
            }
            guard !pageForms.isEmpty else {
                throw BookError.malformedDocument("FORM:DJVM contains no bundled DjVu pages")
            }
        default:
            throw BookError.unsupportedFormat
        }

        let pages = try pageForms.map { form -> DjVuIFFPage in
            guard form.children.first?.id == "INFO" else {
                throw BookError.malformedDocument("FORM:DJVU must begin with an INFO chunk")
            }
            guard let infoChunk = form.children.first else {
                throw BookError.malformedDocument("DjVu page is empty")
            }
            return DjVuIFFPage(
                formOffset: form.headerOffset,
                info: try parseInfo(infoChunk.payload(in: data)),
                chunks: form.children
            )
        }

        return DjVuIFFDocument(formType: formType, root: parsed.chunk, pages: pages)
    }

    private static func parseInfo(_ data: Data) throws -> DjVuPageInfo {
        guard data.count >= 10 else {
            throw BookError.malformedDocument("DjVu INFO chunk must contain at least 10 bytes")
        }
        let bytes = [UInt8](data.prefix(10))
        let width = Int(bytes[0]) << 8 | Int(bytes[1])
        let height = Int(bytes[2]) << 8 | Int(bytes[3])
        let dpi = Int(bytes[6]) | Int(bytes[7]) << 8
        guard width > 0, height > 0 else {
            throw BookError.malformedDocument("DjVu INFO dimensions must be positive")
        }
        guard let rotation = DjVuRotation(rawValue: Int(bytes[9] & 0x07)) else {
            throw BookError.malformedDocument("DjVu INFO contains an unknown rotation flag")
        }
        return DjVuPageInfo(
            width: width,
            height: height,
            minorVersion: Int(bytes[4]),
            majorVersion: Int(bytes[5]),
            dpi: dpi,
            gamma: Double(bytes[8]) / 10,
            rotation: rotation
        )
    }
}

private extension DjVuIFFParser {
    struct ParsedChunk {
        let chunk: DjVuIFFChunk
        let paddedEnd: Int
    }

    struct State {
        let data: Data
        let maxChunkCount: Int
        var chunkCount = 0

        mutating func parseChunk(
            at offset: Int,
            limit: Int,
            depth: Int,
            allowMissingTerminalPadding: Bool = false
        ) throws -> ParsedChunk {
            guard depth <= 8 else {
                throw BookError.invalidContainer("DjVu FORM nesting exceeds the supported limit")
            }
            guard offset >= 0, limit <= data.count, offset <= limit - 8 else {
                throw BookError.invalidContainer("Truncated DjVu chunk header")
            }
            chunkCount += 1
            guard chunkCount <= maxChunkCount else {
                throw BookError.invalidContainer("DjVu chunk count exceeds the configured limit")
            }

            let id = try ascii(at: offset, count: 4)
            let length = try unsigned32(at: offset + 4)
            guard let payloadLength = Int(exactly: length) else {
                throw BookError.invalidContainer("DjVu chunk length is not representable")
            }
            let payloadStart = offset + 8
            guard payloadLength <= limit - payloadStart else {
                throw BookError.invalidContainer("DjVu \(id) chunk extends outside its container")
            }
            let payloadEnd = payloadStart + payloadLength
            let mayOmitPadding = allowMissingTerminalPadding && payloadEnd == limit
            let paddedEnd = payloadEnd + (
                payloadLength.isMultiple(of: 2) || mayOmitPadding ? 0 : 1
            )
            guard paddedEnd <= limit else {
                throw BookError.invalidContainer("DjVu \(id) chunk padding is truncated")
            }

            var formType: String?
            var children: [DjVuIFFChunk] = []
            if id == "FORM" {
                guard payloadLength >= 4 else {
                    throw BookError.invalidContainer("DjVu FORM chunk has no secondary identifier")
                }
                formType = try ascii(at: payloadStart, count: 4)
                var childOffset = payloadStart + 4
                while childOffset < payloadEnd {
                    let child = try parseChunk(
                        at: childOffset,
                        limit: payloadEnd,
                        depth: depth + 1,
                        allowMissingTerminalPadding: true
                    )
                    children.append(child.chunk)
                    guard child.paddedEnd > childOffset else {
                        throw BookError.invalidContainer("DjVu chunk parser made no progress")
                    }
                    childOffset = child.paddedEnd
                }
                guard childOffset == payloadEnd else {
                    throw BookError.invalidContainer("DjVu FORM children do not match its declared length")
                }
            }

            return ParsedChunk(
                chunk: DjVuIFFChunk(
                    id: id,
                    formType: formType,
                    headerOffset: offset,
                    payloadRange: payloadStart..<payloadEnd,
                    children: children
                ),
                paddedEnd: paddedEnd
            )
        }

        private func ascii(at offset: Int, count: Int) throws -> String {
            guard offset >= 0, count >= 0, offset <= data.count - count else {
                throw BookError.invalidContainer("Truncated DjVu identifier")
            }
            let range = offset..<(offset + count)
            guard let value = String(data: data.subdata(in: range), encoding: .ascii),
                  value.utf8.allSatisfy({ (0x20...0x7e).contains($0) })
            else {
                throw BookError.invalidContainer("DjVu chunk identifier is not ASCII")
            }
            return value
        }

        private func unsigned32(at offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else {
                throw BookError.invalidContainer("Truncated DjVu chunk length")
            }
            return data[offset..<(offset + 4)].reduce(UInt32(0)) { partial, byte in
                partial << 8 | UInt32(byte)
            }
        }
    }
}
