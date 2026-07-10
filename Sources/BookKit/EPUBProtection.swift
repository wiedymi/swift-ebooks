import CryptoKit
import Foundation

struct EPUBEncryptionManifest: Sendable, Equatable {
    static let idpfFontObfuscation = "http://www.idpf.org/2008/embedding"

    struct Entry: Sendable, Equatable {
        var algorithm: String?
        var resource: String?
    }

    var entries: [Entry]

    static func parse(_ data: Data) throws -> EPUBEncryptionManifest {
        let delegate = EPUBEncryptionXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw BookError.malformedDocument(
                parser.parserError?.localizedDescription ?? "Unable to parse META-INF/encryption.xml"
            )
        }
        return EPUBEncryptionManifest(entries: delegate.entries)
    }

    func validateDRMFree() throws {
        for entry in entries where entry.algorithm != Self.idpfFontObfuscation {
            throw BookError.protectedContent(
                ContentProtection(
                    kind: .epubEncryption,
                    scheme: entry.algorithm ?? "unspecified EPUB encryption",
                    resource: entry.resource
                )
            )
        }
    }

    var obfuscatedResourcePaths: Set<String> {
        Set(entries.compactMap(\.resource).map(Self.normalizedPath))
    }

    private static func normalizedPath(_ value: String) -> String {
        let withoutFragment = value.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? value
        return (withoutFragment.removingPercentEncoding ?? withoutFragment)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

enum EPUBFontObfuscation {
    static func deobfuscate(_ data: Data, uniqueIdentifier: String) -> Data {
        let identifier = uniqueIdentifier.filter { character in
            character != " " && character != "\t" && character != "\r" && character != "\n"
        }
        let key = Array(Insecure.SHA1.hash(data: Data(identifier.utf8)))
        guard !key.isEmpty, !data.isEmpty else { return data }

        var bytes = [UInt8](data)
        for index in 0..<min(bytes.count, 1_040) {
            bytes[index] ^= key[index % key.count]
        }
        return Data(bytes)
    }
}

private final class EPUBEncryptionXMLDelegate: NSObject, XMLParserDelegate {
    var entries: [EPUBEncryptionManifest.Entry] = []
    private var current: EPUBEncryptionManifest.Entry?

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(elementName) {
        case "EncryptedData":
            current = EPUBEncryptionManifest.Entry()
        case "EncryptionMethod":
            current?.algorithm = attributeDict["Algorithm"] ?? attributeDict["algorithm"]
        case "CipherReference":
            current?.resource = attributeDict["URI"] ?? attributeDict["uri"]
        default:
            break
        }
    }

    func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        guard localName(elementName) == "EncryptedData", let current else { return }
        entries.append(current)
        self.current = nil
    }

    private func localName(_ value: String) -> String {
        value.split(separator: ":").last.map(String.init) ?? value
    }
}
