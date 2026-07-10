import Foundation

enum ZIPArchiveSecurity {
    private static let localFileHeader = UInt32(0x0403_4b50)
    private static let centralDirectoryHeader = UInt32(0x0201_4b50)
    private static let endOfCentralDirectory = UInt32(0x0605_4b50)
    private static let archiveExtraData = UInt32(0x0806_4b50)

    static func validateUnencryptedEntries(in data: Data) throws {
        if data.range(of: littleEndianBytes(archiveExtraData)) != nil {
            throw protectedZIP(scheme: "ZIP archive decryption header")
        }

        if let eocdOffset = endOfCentralDirectoryOffset(in: data),
           let centralOffset = data.uint32LE(at: eocdOffset + 16),
           let entryCount = data.uint16LE(at: eocdOffset + 10)
        {
            var offset = Int(centralOffset)
            var parsedEntries = 0
            while parsedEntries < Int(entryCount),
                  data.uint32LE(at: offset) == centralDirectoryHeader
            {
                guard let flags = data.uint16LE(at: offset + 8),
                      let fileNameLength = data.uint16LE(at: offset + 28),
                      let extraLength = data.uint16LE(at: offset + 30),
                      let commentLength = data.uint16LE(at: offset + 32)
                else {
                    throw BookError.invalidContainer("Truncated ZIP central directory")
                }
                try rejectEncryptionFlags(flags, resource: fileName(in: data, at: offset + 46, length: Int(fileNameLength)))
                offset += 46 + Int(fileNameLength) + Int(extraLength) + Int(commentLength)
                parsedEntries += 1
            }
            if parsedEntries == Int(entryCount) {
                return
            }
        }

        // A partial/local-header-only check is useful for streaming probes and
        // malformed archives that never reach the central-directory parser.
        if data.uint32LE(at: 0) == localFileHeader,
           let flags = data.uint16LE(at: 6)
        {
            let nameLength = Int(data.uint16LE(at: 26) ?? 0)
            try rejectEncryptionFlags(flags, resource: fileName(in: data, at: 30, length: nameLength))
        }
    }

    private static func rejectEncryptionFlags(_ flags: UInt16, resource: String?) throws {
        let isEncrypted = flags & 0x0001 != 0
        let usesStrongEncryption = flags & 0x0040 != 0
        guard !isEncrypted, !usesStrongEncryption else {
            throw protectedZIP(scheme: usesStrongEncryption ? "ZIP strong encryption" : "ZIP encryption", resource: resource)
        }
    }

    private static func protectedZIP(scheme: String, resource: String? = nil) -> BookError {
        .protectedContent(
            ContentProtection(kind: .zipEncryption, scheme: scheme, resource: resource)
        )
    }

    private static func endOfCentralDirectoryOffset(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowerBound = max(0, data.count - 65_557)
        let signature = littleEndianBytes(endOfCentralDirectory)
        return data.range(
            of: signature,
            options: .backwards,
            in: lowerBound..<data.count
        )?.lowerBound
    }

    private static func fileName(in data: Data, at offset: Int, length: Int) -> String? {
        guard length > 0, offset >= 0, offset + length <= data.count else { return nil }
        return String(data: data[offset..<(offset + length)], encoding: .utf8)
    }

    private static func littleEndianBytes(_ value: UInt32) -> Data {
        var value = value.littleEndian
        return Swift.withUnsafeBytes(of: &value) { Data($0) }
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}
