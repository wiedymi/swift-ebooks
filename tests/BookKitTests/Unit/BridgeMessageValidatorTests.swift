import XCTest
@testable import BookKit

final class BridgeMessageValidatorTests: XCTestCase {
    func testDecodesPaginationChanged() {
        let event = BridgeMessageValidator.decode(body: [
            "type": "paginationChanged",
            "pageCount": 5,
            "chapterProgressMap": ["0": [0.0, 0.25, 0.5, 0.75, 1.0]],
        ])

        XCTAssertEqual(
            event,
            .paginationChanged(pageCount: 5, chapterProgressMap: [0: [0.0, 0.25, 0.5, 0.75, 1.0]])
        )
    }

    func testRejectsInvalidPayload() {
        XCTAssertNil(BridgeMessageValidator.decode(body: ["type": "positionChanged", "spineIndex": "a"]))
        XCTAssertNil(BridgeMessageValidator.decode(body: ["foo": "bar"]))
    }

    func testDecodesLinkTappedRelativeURL() {
        let event = BridgeMessageValidator.decode(body: [
            "type": "linkTapped",
            "url": "#note-1",
            "kind": "anchor",
        ])

        switch event {
        case let .linkTapped(url, kind):
            XCTAssertEqual(kind, .anchor)
            XCTAssertEqual(url.fragment, "note-1")
        default:
            XCTFail("Expected linkTapped event")
        }
    }

    func testDecodesSelectionChanged() {
        let event = BridgeMessageValidator.decode(body: [
            "type": "selectionChanged",
            "start": 4,
            "end": 12,
            "text": "highlight",
        ])

        XCTAssertEqual(
            event,
            .selectionChanged(range: SelectionRange(start: 4, end: 12), text: "highlight")
        )
    }

    func testDecodesDecorationTapped() {
        let event = BridgeMessageValidator.decode(body: [
            "type": "decorationTapped",
            "id": "highlight-1",
            "group": "highlight",
        ])

        XCTAssertEqual(event, .decorationTapped(id: "highlight-1", group: .highlight))
    }
}
