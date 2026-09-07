import XCTest
@testable import BookKit

final class BridgeMessageValidatorTests: XCTestCase {
    func testRejectsNonFinitePositionsAndInvalidTextOffsets() {
        XCTAssertNil(BridgeMessageValidator.decode(body: ["type": "positionChanged", "spineIndex": 0, "progression": Double.nan]))
        for value in [Double.infinity, -1.0, 1.5] {
            XCTAssertNil(BridgeMessageValidator.decode(body: ["type": "selectionChanged", "start": value, "end": 8, "text": "text"]))
        }
    }

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

    func testDecodesCustomBridgeMessage() {
        let event = BridgeMessageValidator.decode(body: [
            "type": "custom",
            "name": "example.selection",
            "payload": [
                "text": "hello",
                "count": 2,
                "active": true,
            ],
        ])

        XCTAssertEqual(
            event,
            .custom(
                name: "example.selection",
                payload: .object([
                    "text": .string("hello"),
                    "count": .number(2),
                    "active": .bool(true),
                ])
            )
        )
    }
}
