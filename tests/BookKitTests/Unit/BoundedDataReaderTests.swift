import XCTest
@testable import BookKit

final class BoundedDataReaderTests: XCTestCase {
    func testFileLimitsAtAndAcrossReadBoundaries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for count in [0, 1, 65_536, 65_537] {
            let payload = Data(repeating: 7, count: count)
            try payload.write(to: url)
            XCTAssertEqual(try BoundedDataReader.file(url, limit: max(count, 1)), payload)
            if count > 1 {
                XCTAssertThrowsError(try BoundedDataReader.file(url, limit: count - 1))
            }
        }
        XCTAssertThrowsError(try BoundedDataReader.file(url, limit: 0))
        XCTAssertThrowsError(try BoundedDataReader.file(url, limit: -1))
    }

    @MainActor
    func testRemoteLimitsWithoutWaitingForEndOfResponse() async throws {
        for response in [
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 1000000\r\n\r\nhello",
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n",
        ] {
            let server = try LocalHTTPServer(response: Data(response.utf8), keepsOpen: true)
            let url = try await server.start()
            defer { server.stop() }
            let rejected = expectation(description: "Reject before server ends response")
            let task = Task {
                do {
                    _ = try await BoundedDataReader.remote(url, limit: 4)
                    XCTFail("Expected limit failure")
                } catch BookError.io { rejected.fulfill() }
                catch { XCTFail("Unexpected error: \(error)"); rejected.fulfill() }
            }
            await fulfillment(of: [rejected], timeout: 5)
            task.cancel()
            await task.value
        }
    }

    @MainActor
    func testCancellingAStalledRemoteReadCompletes() async throws {
        let server = try LocalHTTPServer(
            response: Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8),
            keepsOpen: true
        )
        let requested = expectation(description: "Server received request")
        let cancelled = expectation(description: "Read stopped after cancellation")
        server.onRequest = { requested.fulfill() }
        let url = try await server.start()
        defer { server.stop() }
        let task = Task {
            do {
                _ = try await BoundedDataReader.remote(url, limit: 100)
                XCTFail("Expected cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
            }
            cancelled.fulfill()
        }
        await fulfillment(of: [requested], timeout: 5)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 5)
        server.stop()
        await task.value
    }

    @MainActor
    func testRemoteSourceAndResourceExactLimitAndHTTPError() async throws {
        for (status, body) in [(200, "hello"), (404, "missing")] {
            let response = "HTTP/1.1 \(status) Test\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            let server = try LocalHTTPServer(response: Data(response.utf8))
            let url = try await server.start()
            defer { server.stop() }
            let book = try await Book.open(source: .data(Data("test".utf8), fileName: "test.txt"))
            let loader = ResourceLoader(book: book, options: OpenOptions(allowsNetwork: true), maxAssetBytes: 5)
            do {
                let resource = try await loader.data(for: url)
                XCTAssertEqual(status, 200)
                XCTAssertEqual(resource, Data(body.utf8))
            } catch BookError.io { XCTAssertEqual(status, 404) }
            do {
                let data = try await BookSource.url(url).loadData(options: OpenOptions(allowsNetwork: true, maxSourceBytes: 5))
                XCTAssertEqual(status, 200)
                XCTAssertEqual(data, Data(body.utf8))
            } catch BookError.io { XCTAssertEqual(status, 404) }
        }
    }
}
