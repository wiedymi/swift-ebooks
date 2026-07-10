import XCTest
@testable import BookKit

final class ContentProtectionTests: XCTestCase {
    func testDetectsProtectedISOAudioContainer() throws {
        var data = Data([0, 0, 0, 16])
        data.append(Data("ftyp".utf8))
        data.append(Data("M4A ".utf8))
        data.append(Data([0, 0, 0, 0]))
        data.append(Data([0, 0, 0, 8]))
        data.append(Data("sinf".utf8))

        XCTAssertTrue(AudioProtectionProbe.containsProtection(data))
        XCTAssertThrowsError(try AudioProtectionProbe.validate(data, resource: "book.m4b")) {
            guard case let BookError.protectedContent(protection) = $0 else {
                return XCTFail("Expected protectedContent, got \($0)")
            }
            XCTAssertEqual(protection.kind, .audioDRM)
        }
    }

    func testPDFEncryptionFallbackProbeUsesNameDelimiter() {
        XCTAssertTrue(
            PDFProtectionProbe.containsEncryptionDictionary(
                Data("%PDF-1.7\ntrailer << /Encrypt 4 0 R >>".utf8)
            )
        )
        XCTAssertFalse(
            PDFProtectionProbe.containsEncryptionDictionary(
                Data("%PDF-1.7\n/EncryptedLabel (not a dictionary key)".utf8)
            )
        )
    }

    func testEncryptedZIPEntryIsRejectedBeforeExtraction() throws {
        var zip = Data()
        zip.appendLittleEndian(UInt32(0x0403_4b50))
        zip.appendLittleEndian(UInt16(20))
        zip.appendLittleEndian(UInt16(1)) // Traditional ZIP encryption flag.
        zip.append(Data(repeating: 0, count: 22))

        XCTAssertThrowsError(try ZIPArchiveSecurity.validateUnencryptedEntries(in: zip)) { error in
            guard case let BookError.protectedContent(protection) = error else {
                return XCTFail("Expected protectedContent, got \(error)")
            }
            XCTAssertEqual(protection.kind, .zipEncryption)
        }
    }

    func testUnencryptedZIPHeaderPassesProtectionCheck() throws {
        var zip = Data()
        zip.appendLittleEndian(UInt32(0x0403_4b50))
        zip.appendLittleEndian(UInt16(20))
        zip.appendLittleEndian(UInt16(0))
        zip.append(Data(repeating: 0, count: 22))

        XCTAssertNoThrow(try ZIPArchiveSecurity.validateUnencryptedEntries(in: zip))
    }

    func testProtectionErrorExplainsSchemeAndResource() {
        let protection = ContentProtection(
            kind: .epubEncryption,
            scheme: "urn:vendor:drm",
            resource: "OPS/chapter.xhtml"
        )
        let error = BookError.protectedContent(protection)

        XCTAssertTrue(error.localizedDescription.contains("DRM-free"))
        XCTAssertTrue(error.localizedDescription.contains("urn:vendor:drm"))
        XCTAssertTrue(error.localizedDescription.contains("OPS/chapter.xhtml"))
    }

    func testEPUBRejectsUnknownEncryptionAlgorithm() throws {
        let xml = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="urn:vendor:drm"/>
            <enc:CipherData><enc:CipherReference URI="OPS/chapter.xhtml"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        let manifest = try EPUBEncryptionManifest.parse(Data(xml.utf8))

        XCTAssertThrowsError(try manifest.validateDRMFree()) { error in
            guard case let BookError.protectedContent(protection) = error else {
                return XCTFail("Expected protectedContent, got \(error)")
            }
            XCTAssertEqual(protection.kind, .epubEncryption)
            XCTAssertEqual(protection.scheme, "urn:vendor:drm")
            XCTAssertEqual(protection.resource, "OPS/chapter.xhtml")
        }
    }

    func testEPUBAllowsAndReversesStandardFontObfuscation() throws {
        let xml = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
            <enc:CipherData><enc:CipherReference URI="OPS/Fonts/Book.otf"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        let manifest = try EPUBEncryptionManifest.parse(Data(xml.utf8))
        XCTAssertNoThrow(try manifest.validateDRMFree())
        XCTAssertEqual(manifest.obfuscatedResourcePaths, ["OPS/Fonts/Book.otf"])

        let original = Data((0..<1_500).map { UInt8($0 % 251) })
        let obfuscated = EPUBFontObfuscation.deobfuscate(original, uniqueIdentifier: " urn:uuid:book \n")
        let restored = EPUBFontObfuscation.deobfuscate(obfuscated, uniqueIdentifier: "urn:uuid:book")
        XCTAssertNotEqual(obfuscated, original)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(obfuscated.suffix(460), original.suffix(460))
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
