import Foundation

public enum BookFormat: String, CaseIterable, Sendable, Equatable, Hashable {
    case epub
    case fb2
    case mobi
    case azw3
    case pdf
    case cbz
    case text
    case html
    case markdown
    case audiobook
    case djvu

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "epub": self = .epub
        case "fb2": self = .fb2
        case "mobi": self = .mobi
        case "azw3", "kf8": self = .azw3
        case "pdf": self = .pdf
        case "cbz": self = .cbz
        case "txt", "text": self = .text
        case "html", "htm", "xhtml": self = .html
        case "md", "markdown": self = .markdown
        case "readium-audiobook", "audiobook", "lpf", "mp3", "m4a", "m4b", "aac": self = .audiobook
        case "djvu", "djv": self = .djvu
        default: return nil
        }
    }
}

public enum FormatSniffer {
    public static func detect(fileName: String) -> BookFormat? {
        if fileName.lowercased().hasSuffix(".fb2.zip") {
            return .fb2
        }
        return BookFormat(fileExtension: URL(fileURLWithPath: fileName).pathExtension)
    }

    public static func detect(data: Data, fileName: String?) -> BookFormat? {
        if let fileName, let extFormat = detect(fileName: fileName) {
            return extFormat
        }

        if data.starts(with: Data("%PDF-".utf8)) {
            return .pdf
        }

        // Secure DjVu uses a distinct encrypted container signature. Detect it
        // as DjVu so the parser can report protected content instead of a
        // misleading unsupported-format error.
        if data.starts(with: Data("SDJV".utf8)) {
            return .djvu
        }

        if data.count >= 16,
           data.starts(with: Data("AT&TFORM".utf8)),
           let form = String(data: data[12..<16], encoding: .ascii),
           ["DJVU", "DJVM", "PM44", "BM44"].contains(form)
        {
            return .djvu
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

        if data.starts(with: Data("ID3".utf8)) ||
            (data.count >= 2 && data[0] == 0xff && data[1] & 0xf0 == 0xf0)
        {
            return .audiobook
        }

        if let prefix = String(data: data.prefix(256 * 1024), encoding: .utf8) {
            let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = trimmed.lowercased()
            if lowercased.hasPrefix("<!doctype html") ||
                lowercased.hasPrefix("<html") ||
                lowercased.contains("<body")
            {
                return .html
            }
            if trimmed.range(
                of: "(?m)^(?:#{1,6}\\s+|(?:[-*+]\\s+)|(?:```))",
                options: .regularExpression
            ) != nil {
                return .markdown
            }
            if trimmed.hasPrefix("{"),
               lowercased.contains("\"readingorder\""),
               (lowercased.contains("audiobook") || lowercased.contains("audio/"))
            {
                return .audiobook
            }
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
