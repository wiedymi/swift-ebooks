import Foundation

/// Conservative container-level protection detection used before the native
/// AVFoundation check and on platforms where that property is unavailable.
enum AudioProtectionProbe {
    private static let protectedBoxTypes = ["sinf", "schm", "drms", "enca", "encv"]

    static func validate(_ data: Data, resource: String?) throws {
        guard containsProtection(data) else { return }
        throw BookError.protectedContent(
            ContentProtection(
                kind: .audioDRM,
                scheme: "protected ISO base media",
                resource: resource
            )
        )
    }

    static func validateFile(at url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try validate(data, resource: url.lastPathComponent)
    }

    static func containsProtection(_ data: Data) -> Bool {
        guard isISOBaseMedia(data) else { return false }
        for type in protectedBoxTypes {
            let marker = Data(type.utf8)
            var searchStart = data.startIndex
            while searchStart <= data.endIndex - marker.count,
                  let range = data.range(
                      of: marker,
                      options: [],
                      in: searchStart..<data.endIndex
                  )
            {
                let typeOffset = range.lowerBound
                if typeOffset >= 4,
                   let size = data.uint32BigEndian(at: typeOffset - 4),
                   size >= 8,
                   UInt64(typeOffset - 4) + UInt64(size) <= UInt64(data.count)
                {
                    return true
                }
                searchStart = range.upperBound
            }
        }
        return false
    }

    private static func isISOBaseMedia(_ data: Data) -> Bool {
        data.count >= 12 && data[4..<8] == Data("ftyp".utf8)
    }
}

private extension Data {
    func uint32BigEndian(at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= count - 4 else { return nil }
        return self[offset..<(offset + 4)].reduce(UInt32(0)) {
            $0 << 8 | UInt32($1)
        }
    }
}
