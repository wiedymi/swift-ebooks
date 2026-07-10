import Foundation
@testable import BookKit

struct CorpusEntry: Equatable {
    let id: String
    let format: BookFormat
    let path: String
    let sha256: String
    let bytes: Int
    let license: String
    let source: String
    let notes: String

    var fileURL: URL {
        let root = TestPaths.repositoryRoot()
        return root.appendingPathComponent(path)
    }
}

enum CorpusManifest {
    static func load() throws -> [CorpusEntry] {
        let data = try Data(contentsOf: TestPaths.corpusManifest)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "CorpusManifest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Manifest is not UTF-8"])
        }

        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { !$0.hasPrefix("#") }

        return try lines.map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 8 else {
                throw NSError(domain: "CorpusManifest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid line: \(line)"])
            }
            guard let format = BookFormat(rawValue: fields[1]) else {
                throw NSError(domain: "CorpusManifest", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unknown format: \(fields[1])"])
            }
            guard let bytes = Int(fields[4]) else {
                throw NSError(domain: "CorpusManifest", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid byte size: \(fields[4])"])
            }

            return CorpusEntry(
                id: fields[0],
                format: format,
                path: fields[2],
                sha256: fields[3],
                bytes: bytes,
                license: fields[5],
                source: fields[6],
                notes: fields[7]
            )
        }
    }
}
