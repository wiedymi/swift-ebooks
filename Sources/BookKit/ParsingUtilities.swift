import Foundation

extension String {
    func firstMatch(for pattern: String, options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        guard let match = regex.firstMatch(in: self, options: [], range: NSRange(startIndex..<endIndex, in: self)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: self)
        else {
            return nil
        }
        return String(self[range]).strippingHTML().normalizedWhitespace()
    }

    func allMatches(for pattern: String, options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        let matches = regex.matches(in: self, options: [], range: NSRange(startIndex..<endIndex, in: self))
        return matches.compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: self) else {
                return nil
            }
            return String(self[range])
        }
    }

    func strippingHTML() -> String {
        var result = self
        result = result.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        return result
    }

    func normalizedWhitespace() -> String {
        replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Data {
    func asciiStrings(minLength: Int = 4) -> [String] {
        var current: [UInt8] = []
        var out: [String] = []

        for byte in self {
            let isPrintable = (32...126).contains(byte)
            if isPrintable {
                current.append(byte)
            } else {
                if current.count >= minLength, let str = String(bytes: current, encoding: .ascii) {
                    out.append(str)
                }
                current.removeAll(keepingCapacity: true)
            }
        }

        if current.count >= minLength, let str = String(bytes: current, encoding: .ascii) {
            out.append(str)
        }

        return out
    }

    func bestEffortString() -> String {
        if let utf8 = String(data: self, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: self, encoding: .isoLatin1) {
            return latin1
        }
        return String(decoding: self, as: UTF8.self)
    }
}

extension URL {
    func appendingPathIfNeeded(_ childPath: String) -> URL {
        if childPath.hasPrefix("/") {
            return URL(fileURLWithPath: childPath)
        }
        return appendingPathComponent(childPath)
    }
}
