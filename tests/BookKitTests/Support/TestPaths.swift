import Foundation

enum TestPaths {
    static func repositoryRoot(from filePath: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: filePath)
        for _ in 0..<12 {
            let candidate = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
                return candidate
            }
            url = candidate
        }
        preconditionFailure("Failed to locate repository root from \(filePath)")
    }

    static var corpusManifest: URL {
        repositoryRoot().appendingPathComponent("tests/corpus/manifest.tsv")
    }

    static var corpusRoot: URL {
        repositoryRoot().appendingPathComponent("tests/corpus")
    }
}
