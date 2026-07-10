#if canImport(WebKit)
import XCTest
@testable import BookKit

@MainActor
final class WebViewReflowBridgeTests: XCTestCase {
    func testBootstrapCanPostReadyEventToNativeHandler() async throws {
        let bridge = WebViewReflowBridge()
        try await Task.sleep(nanoseconds: 100_000_000)

        try await bridge.setContent(
            html: "<p>Hello</p>",
            css: "",
            viewport: Viewport(width: 390, height: 844)
        )

        let event = await firstReadyEvent(from: bridge.events)
        XCTAssertEqual(event, .ready)
    }

    private func firstReadyEvent(from events: AsyncStream<ReflowBridgeEvent>) async -> ReflowBridgeEvent? {
        await withTaskGroup(of: ReflowBridgeEvent?.self) { group in
            group.addTask {
                for await event in events {
                    if event == .ready {
                        return event
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
#endif
