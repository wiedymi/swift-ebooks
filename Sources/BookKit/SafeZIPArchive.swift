import Foundation
import ZIPFoundation

final class SafeZIPArchive {
    struct File {
        let path: String
        let compressedSize: UInt64
        let uncompressedSize: UInt64
    }

    private let archive: Archive
    let files: [File]

    init(data: Data, options: OpenOptions, kind: String) throws {
        try ZIPArchiveSecurity.validateUnencryptedEntries(in: data)
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw BookError.invalidContainer("Unable to read \(kind) ZIP archive")
        }

        var discovered: [File] = []
        var totalUncompressedBytes: UInt64 = 0
        for entry in archive where entry.type == .file {
            guard discovered.count < options.maxArchiveEntries else {
                throw BookError.invalidContainer(
                    "\(kind) archive exceeds the configured entry-count limit"
                )
            }
            guard Self.isSafe(path: entry.path) else {
                throw BookError.invalidContainer("\(kind) archive contains an unsafe path: \(entry.path)")
            }
            guard entry.uncompressedSize <= UInt64(options.maxResourceBytes) else {
                throw BookError.invalidContainer(
                    "\(kind) entry \(entry.path) exceeds the configured resource size limit"
                )
            }
            let (nextTotal, overflow) = totalUncompressedBytes.addingReportingOverflow(
                entry.uncompressedSize
            )
            guard !overflow, nextTotal <= UInt64(options.maxArchiveUncompressedBytes) else {
                throw BookError.invalidContainer(
                    "\(kind) archive exceeds the configured uncompressed size limit"
                )
            }
            totalUncompressedBytes = nextTotal
            discovered.append(
                File(
                    path: entry.path,
                    compressedSize: entry.compressedSize,
                    uncompressedSize: entry.uncompressedSize
                )
            )
        }
        files = discovered
    }

    func data(at path: String) throws -> Data? {
        let normalized = Self.normalized(path)
        let candidates = [
            normalized,
            normalized.removingPercentEncoding ?? normalized,
            String(normalized.drop(while: { $0 == "/" })),
        ]
        for candidate in candidates {
            guard let entry = archive[candidate] else { continue }
            var result = Data()
            result.reserveCapacity(Int(entry.uncompressedSize))
            _ = try archive.extract(entry) { result.append($0) }
            return result
        }
        return nil
    }

    static func normalized(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
            .map(String.init)
            .joined(separator: "/")
    }

    private static func isSafe(path: String) -> Bool {
        let replaced = path.replacingOccurrences(of: "\\", with: "/")
        guard !replaced.hasPrefix("/"),
              replaced.range(of: "^[A-Za-z]:/", options: .regularExpression) == nil
        else {
            return false
        }
        var depth = 0
        for component in replaced.split(separator: "/", omittingEmptySubsequences: false) {
            if component == ".." {
                depth -= 1
            } else if !component.isEmpty, component != "." {
                depth += 1
            }
            if depth < 0 { return false }
        }
        return true
    }
}
