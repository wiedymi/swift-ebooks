import Foundation

public enum BookFormat: String, CaseIterable, Sendable, Equatable, Hashable {
    case epub
    case fb2
    case mobi
    case azw3
    case pdf

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "epub": self = .epub
        case "fb2": self = .fb2
        case "mobi": self = .mobi
        case "azw3", "kf8": self = .azw3
        case "pdf": self = .pdf
        default: return nil
        }
    }
}

public enum FormatSniffer {
    public static func detect(fileName: String) -> BookFormat? {
        BookFormat(fileExtension: URL(fileURLWithPath: fileName).pathExtension)
    }

    public static func detect(data: Data, fileName: String?) -> BookFormat? {
        if let fileName, let extFormat = detect(fileName: fileName) {
            return extFormat
        }

        if data.starts(with: Data("%PDF-".utf8)) {
            return .pdf
        }

        if dataContains(data, ascii: "<FictionBook") {
            return .fb2
        }

        if dataContains(data, ascii: "BOOKMOBI") {
            return .mobi
        }

        if data.starts(with: Data([0x50, 0x4b, 0x03, 0x04])) && dataContains(data, ascii: "application/epub+zip") {
            return .epub
        }

        return nil
    }

    private static func dataContains(_ data: Data, ascii: String) -> Bool {
        guard let needle = ascii.data(using: .utf8), !needle.isEmpty else {
            return false
        }
        return data.range(of: needle, options: [], in: data.startIndex..<min(data.endIndex, data.startIndex + 256 * 1024)) != nil
    }
}
