import Foundation

struct DjVuDirectory: Sendable, Equatable {
    enum ComponentKind: Int, Sendable, Equatable {
        case included = 0
        case page = 1
        case thumbnails = 2
    }

    struct Entry: Sendable, Equatable {
        var offset: Int?
        var size: Int
        var kind: ComponentKind?
        var id: String
        var name: String
        var title: String?
    }

    var isBundled: Bool
    var version: Int
    var entries: [Entry]

    var pages: [Entry] {
        entries.filter { $0.kind == .page }
    }
}

enum DjVuDirectoryParser {
    static func parse(
        chunk: DjVuIFFChunk,
        documentData: Data,
        options: OpenOptions
    ) throws -> DjVuDirectory {
        var header = DjVuByteCursor(chunk.payload(in: documentData))
        let flags = try header.readByte(context: "DIRM flags")
        let isBundled = flags & 0x80 != 0
        let version = Int(flags & 0x7f)
        let count = try header.readUInt16(context: "DIRM component count")
        guard count <= options.maxArchiveEntries else {
            throw BookError.invalidContainer("DjVu directory entry count exceeds the configured limit")
        }

        var offsets = [Int?](repeating: nil, count: count)
        if isBundled {
            for index in 0..<count {
                let offset = try header.readUInt32(context: "DIRM component offset")
                guard offset < documentData.count else {
                    throw BookError.malformedDocument("DjVu directory component offset is outside the file")
                }
                offsets[index] = offset
            }
        }
        guard header.remaining > 0 else {
            throw BookError.malformedDocument("DjVu directory has no compressed entry data")
        }

        let decoded = try DjVuBZZDecoder.decode(
            header.readRemaining(),
            maxOutputBytes: min(options.maxResourceBytes, options.maxArchiveUncompressedBytes)
        )
        var cursor = DjVuByteCursor(decoded)
        var sizes: [Int] = []
        sizes.reserveCapacity(count)
        for _ in 0..<count {
            sizes.append(try cursor.readUInt24(context: "DIRM component size"))
        }
        var entryFlags: [UInt8] = []
        entryFlags.reserveCapacity(count)
        for _ in 0..<count {
            entryFlags.append(try cursor.readByte(context: "DIRM component flags"))
        }

        var entries: [DjVuDirectory.Entry] = []
        entries.reserveCapacity(count)
        for index in 0..<count {
            let entryFlag = entryFlags[index]
            let id = try cursor.readZeroTerminatedUTF8(context: "DIRM component ID")
            guard !id.isEmpty else {
                throw BookError.malformedDocument("DjVu directory component ID is empty")
            }
            let name = entryFlag & 0x80 != 0
                ? try cursor.readZeroTerminatedUTF8(context: "DIRM component name")
                : id
            let title = entryFlag & 0x40 != 0
                ? try cursor.readZeroTerminatedUTF8(context: "DIRM component title")
                : nil
            entries.append(
                DjVuDirectory.Entry(
                    offset: offsets[index],
                    size: sizes[index],
                    kind: DjVuDirectory.ComponentKind(rawValue: Int(entryFlag & 0x3f)),
                    id: id,
                    name: name,
                    title: title?.isEmpty == false ? title : nil
                )
            )
        }
        guard cursor.remaining == 0 else {
            throw BookError.malformedDocument("DjVu directory contains trailing decoded data")
        }
        return DjVuDirectory(isBundled: isBundled, version: version, entries: entries)
    }
}

enum DjVuOutlineParser {
    static func parse(
        chunk: DjVuIFFChunk,
        documentData: Data,
        directory: DjVuDirectory?,
        options: OpenOptions
    ) throws -> [TOCNode] {
        let decoded = try DjVuBZZDecoder.decode(
            chunk.payload(in: documentData),
            maxOutputBytes: options.maxResourceBytes
        )
        var cursor = DjVuByteCursor(decoded)
        let declaredCount = try cursor.readUInt16(context: "NAVM bookmark count")
        guard declaredCount <= options.maxArchiveEntries else {
            throw BookError.invalidContainer("DjVu outline entry count exceeds the configured limit")
        }
        var decodedCount = 0
        var roots: [TOCNode] = []
        while decodedCount < declaredCount {
            roots.append(
                try readNode(
                    cursor: &cursor,
                    directory: directory,
                    declaredCount: declaredCount,
                    decodedCount: &decodedCount,
                    depth: 0
                )
            )
        }
        guard decodedCount == declaredCount, cursor.remaining == 0 else {
            throw BookError.malformedDocument("DjVu outline record count is inconsistent")
        }
        return roots
    }

    private static func readNode(
        cursor: inout DjVuByteCursor,
        directory: DjVuDirectory?,
        declaredCount: Int,
        decodedCount: inout Int,
        depth: Int
    ) throws -> TOCNode {
        guard depth <= 32, decodedCount < declaredCount else {
            throw BookError.malformedDocument("DjVu outline nesting or count is invalid")
        }
        let ordinal = decodedCount
        decodedCount += 1
        let childCount = Int(try cursor.readByte(context: "NAVM child count"))
        let titleLength = try cursor.readUInt24(context: "NAVM title length")
        let title = try cursor.readUTF8(count: titleLength, context: "NAVM title")
        let hrefLength = try cursor.readUInt24(context: "NAVM URL length")
        let rawHref = try cursor.readUTF8(count: hrefLength, context: "NAVM URL")
        var children: [TOCNode] = []
        children.reserveCapacity(childCount)
        for _ in 0..<childCount {
            children.append(
                try readNode(
                    cursor: &cursor,
                    directory: directory,
                    declaredCount: declaredCount,
                    decodedCount: &decodedCount,
                    depth: depth + 1
                )
            )
        }
        return TOCNode(
            id: "djvu-outline-\(ordinal + 1)",
            title: title.isEmpty ? "Untitled" : title,
            href: DjVuNavigationTarget.resolve(rawHref, directory: directory),
            children: children
        )
    }
}

enum DjVuNavigationTarget {
    static func resolve(
        _ href: String,
        directory: DjVuDirectory?,
        currentPageIndex: Int? = nil,
        pageCount: Int? = nil
    ) -> String {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return href }
        if let url = URL(string: trimmed), url.scheme != nil {
            return href
        }

        let withoutPrefix = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        let parts = withoutPrefix.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let target = String(parts[0])
        let fragment = parts.count > 1 ? "#\(parts[1])" : ""

        if (target.hasPrefix("+") || target.hasPrefix("-")),
           let currentPageIndex,
           let delta = Int(target)
        {
            let destination = currentPageIndex + delta
            let knownPageCount = pageCount ?? directory?.pages.count
            guard destination >= 0,
                  knownPageCount.map({ destination < $0 }) ?? true
            else {
                return href
            }
            return "page-\(destination + 1)\(fragment)"
        }
        if let pageNumber = Int(target), pageNumber > 0 {
            return "page-\(pageNumber)\(fragment)"
        }
        if target.lowercased().hasPrefix("page="),
           let pageNumber = Int(target.dropFirst(5)),
           pageNumber > 0
        {
            return "page-\(pageNumber)\(fragment)"
        }
        guard let pages = directory?.pages,
              let index = pages.firstIndex(where: {
                  $0.id.caseInsensitiveCompare(target) == .orderedSame ||
                      $0.name.caseInsensitiveCompare(target) == .orderedSame
              })
        else {
            return href
        }
        return "page-\(index + 1)\(fragment)"
    }
}

struct DjVuByteCursor {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int { data.count - offset }

    mutating func readByte(context: String) throws -> UInt8 {
        guard remaining >= 1 else { throw truncated(context) }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16(context: String) throws -> Int {
        let bytes = try read(count: 2, context: context)
        return Int(bytes[0]) << 8 | Int(bytes[1])
    }

    mutating func readUInt24(context: String) throws -> Int {
        let bytes = try read(count: 3, context: context)
        return Int(bytes[0]) << 16 | Int(bytes[1]) << 8 | Int(bytes[2])
    }

    mutating func readUInt32(context: String) throws -> Int {
        let bytes = try read(count: 4, context: context)
        let value = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard let result = Int(exactly: value) else {
            throw BookError.malformedDocument("DjVu \(context) is not representable")
        }
        return result
    }

    mutating func readUTF8(count: Int, context: String) throws -> String {
        let value = try read(count: count, context: context)
        guard let string = String(data: value, encoding: .utf8) else {
            throw BookError.malformedDocument("DjVu \(context) is not valid UTF-8")
        }
        return string
    }

    mutating func readZeroTerminatedUTF8(context: String) throws -> String {
        guard let end = data[offset...].firstIndex(of: 0) else {
            throw BookError.malformedDocument("DjVu \(context) is not zero terminated")
        }
        let count = end - offset
        let value = try readUTF8(count: count, context: context)
        _ = try readByte(context: context)
        return value
    }

    mutating func readRemaining() -> Data {
        defer { offset = data.count }
        return data.subdata(in: offset..<data.count)
    }

    mutating func readData(count: Int, context: String) throws -> Data {
        try read(count: count, context: context)
    }

    private mutating func read(count: Int, context: String) throws -> Data {
        guard count >= 0, count <= remaining else { throw truncated(context) }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    private func truncated(_ context: String) -> BookError {
        BookError.malformedDocument("DjVu \(context) is truncated")
    }
}
