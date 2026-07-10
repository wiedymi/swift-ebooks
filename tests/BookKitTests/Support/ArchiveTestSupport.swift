import Foundation
import ZIPFoundation

enum ArchiveTestSupport {
    static func makeZIP(_ entries: [(path: String, data: Data)]) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for entry in entries {
            try archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: Int64(entry.data.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, entry.data.count)
                guard start < end else { return Data() }
                return entry.data[start..<end]
            }
        }
        guard let data = archive.data else {
            throw CocoaError(.fileReadUnknown)
        }
        return data
    }
}
