import XCTest
@testable import BookKit

final class AudiobookParserTests: XCTestCase {
    func testParsesReadiumManifestMetadataTracksCoverAndTOC() async throws {
        let manifest = """
        {
          "metadata": {
            "identifier": "urn:isbn:9780000000001",
            "title": "Readium Audio",
            "author": [{"name": "Ada Author"}],
            "narrator": ["Nora Narrator"],
            "language": "en",
            "publisher": "Audio Press",
            "published": "2026-07-10",
            "duration": 90
          },
          "readingOrder": [
            {"href": "https://example.com/01.mp3", "type": "audio/mpeg", "title": "One", "duration": 40},
            {"href": "https://example.com/02.mp3", "type": "audio/mpeg", "title": "Two", "duration": 50}
          ],
          "resources": [
            {"rel": ["cover"], "href": "https://example.com/cover.jpg", "type": "image/jpeg"}
          ],
          "toc": [
            {"title": "Part One", "href": "https://example.com/01.mp3", "children": [
              {"title": "Part Two", "href": "https://example.com/02.mp3"}
            ]}
          ]
        }
        """

        let book = try await Book.open(
            source: .data(Data(manifest.utf8), fileName: "book.readium-audiobook")
        )

        XCTAssertEqual(book.format, .audiobook)
        XCTAssertEqual(book.metadata.title, "Readium Audio")
        XCTAssertEqual(book.metadata.authors, ["Ada Author"])
        XCTAssertEqual(book.metadata.language, "en")
        XCTAssertEqual(book.metadata.publisher, "Audio Press")
        XCTAssertEqual(book.metadata.publicationDate, "2026-07-10")
        XCTAssertEqual(book.presentation.layout, .audiobook)
        XCTAssertEqual(book.readingOrder.map(\.audio?.duration), [40, 50])
        XCTAssertEqual(book.tableOfContents[0].children.map(\.title), ["Part Two"])
        XCTAssertEqual(book.rawExtensions["bookkit:audiobook:narrators"], "Nora Narrator")
        XCTAssertEqual(book.rawExtensions["bookkit:audiobook:duration"], "90.0")
        XCTAssertEqual(book.assets.first(where: { $0.mediaType == "image/jpeg" })?.href, "https://example.com/cover.jpg")
    }

    func testParsesW3CManifestISODurationsAndMediaFragments() async throws {
        let manifest = """
        {
          "@context": ["https://schema.org", "https://www.w3.org/ns/pub-context"],
          "conformsTo": "https://www.w3.org/TR/audiobooks/",
          "type": "Audiobook",
          "id": "urn:book:w3c",
          "name": "W3C Audio",
          "author": "W3C Author",
          "readBy": "W3C Narrator",
          "inLanguage": "en-GB",
          "duration": "PT1M30S",
          "readingOrder": [
            {
              "url": "audio/book.mp3#t=12.5,42.5",
              "encodingFormat": "audio/mpeg",
              "name": "Excerpt",
              "duration": "PT30S"
            }
          ]
        }
        """

        let book = try await AudiobookParser().parse(
            source: .data(Data(manifest.utf8), fileName: "manifest.json"),
            options: OpenOptions()
        )

        XCTAssertEqual(book.id, "urn:book:w3c")
        XCTAssertEqual(book.metadata.title, "W3C Audio")
        XCTAssertEqual(book.readingOrder[0].audio?.duration, 30)
        XCTAssertEqual(book.readingOrder[0].audio?.clipBegin, 12.5)
        XCTAssertEqual(book.readingOrder[0].audio?.clipEnd, 42.5)
        XCTAssertEqual(book.rawExtensions["bookkit:audiobook:duration"], "90.0")
    }

    func testParsesPackagedAudiobookAndEmbedsRequiredResources() async throws {
        let manifest = """
        {
          "metadata": {"title": "Packaged Audio", "duration": 5},
          "readingOrder": [
            {"href": "audio/one.mp3", "type": "audio/mpeg", "title": "One", "duration": 5}
          ],
          "resources": [
            {"rel": "cover", "href": "images/cover.png", "type": "image/png"}
          ]
        }
        """
        let package = try ArchiveTestSupport.makeZIP([
            ("manifest.json", Data(manifest.utf8)),
            ("audio/one.mp3", Data("ID3audio".utf8)),
            ("images/cover.png", Data([0x89, 0x50, 0x4e, 0x47])),
        ])

        let book = try await AudiobookParser().parse(
            source: .data(package, fileName: "book.audiobook"),
            options: OpenOptions()
        )

        XCTAssertEqual(book.readingOrder[0].resourceID, "audio-track-1")
        XCTAssertEqual(book.assets.first(where: { $0.id == "audio-track-1" })?.data, Data("ID3audio".utf8))
        XCTAssertEqual(book.assets.first(where: { $0.mediaType == "image/png" })?.data, Data([0x89, 0x50, 0x4e, 0x47]))
        XCTAssertEqual(book.rawExtensions["bookkit:container"], "audiobook.zip")
    }

    func testRejectsManifestEncryptedLinkProperties() async throws {
        let manifest = """
        {
          "metadata": {"title": "Protected", "duration": 5},
          "readingOrder": [{
            "href": "audio.mp3",
            "type": "audio/mpeg",
            "duration": 5,
            "properties": {"encrypted": {"scheme": "http://readium.org/2014/01/lcp"}}
          }]
        }
        """

        do {
            _ = try await AudiobookParser().parse(
                source: .data(Data(manifest.utf8), fileName: "protected.readium-audiobook"),
                options: OpenOptions()
            )
            XCTFail("Expected protectedContent")
        } catch let BookError.protectedContent(protection) {
            XCTAssertEqual(protection.kind, .audioDRM)
            XCTAssertEqual(protection.resource, "audio.mp3")
        }
    }

    func testStandaloneMP3IsInspectedByAVFoundation() async throws {
        let mp3 = AudioTestFixture.silentMP3
        let book = try await AudiobookParser().parse(
            source: .data(mp3, fileName: "sample.mp3"),
            options: OpenOptions()
        )

        XCTAssertEqual(book.version, "standalone")
        XCTAssertEqual(book.metadata.title, "sample")
        XCTAssertEqual(book.readingOrder.count, 1)
        XCTAssertGreaterThan(book.readingOrder[0].audio?.duration ?? 0, 0)
        XCTAssertEqual(book.assets[0].data, mp3)
    }

    private static let silentMP3Base64 = """
    SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjYyLjEyLjEwMAAAAAAAAAAAAAAA/+M4wAAAAAAAAAAAAEluZm8AAAAPAAAABAAAAxgAdHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0oqKioqKioqKioqKioqKioqKioqKioqKiotHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dH/////////////////////////////////AAAAAExhdmM2Mi4yOAAAAAAAAAAAAAAAACQDoAAAAAAAAAMYnchARgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/+MoxAAAAANIAAAAAExBTUVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+MoxHwAAANIAAAAAFVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+MoxHwAAANIAAAAAFVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+MoxHwAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
    """
}
