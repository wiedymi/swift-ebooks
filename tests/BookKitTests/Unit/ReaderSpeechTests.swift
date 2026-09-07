import XCTest

@testable import BookKit

@MainActor
final class ReaderSpeechTests: XCTestCase {
    func testDefaultSpeechCanStartBeforeViewIsMounted() async throws {
        let engine = TestSpeechEngine()
        let reader = try await BookReader(
            book: makeTextBook("<p>Speak before presentation.</p>"),
            configuration: .init(speechEngine: engine))
        let spoken = expectation(description: "Speech started")
        engine.onSpeak = { _ in spoken.fulfill() }
        reader.speech.start()
        await fulfillment(of: [spoken], timeout: 3)
        XCTAssertEqual(reader.speech.state, .speaking)
        await reader.shutdown()
    }

    func testCustomEngineReceivesTextVoiceOptionsAndWordLocations() async throws {
        let engine = TestSpeechEngine()
        let reader = try await BookReader(
            book: makeTextBook("<p>First sentence. Second sentence.</p>"),
            configuration: .init(speechEngine: engine))
        reader.speech.followsText = false
        reader.speech.highlightsText = false
        let first = expectation(description: "First speech")
        engine.onSpeak = { text in
            XCTAssertEqual(text, "First sentence. ")
            first.fulfill()
        }
        reader.speech.start(options: .init(language: "en-GB", rate: 0.4))
        await fulfillment(of: [first], timeout: 3)
        XCTAssertEqual(engine.options?.language, "en-GB")
        engine.onRange?(NSRange(location: 6, length: 8))
        XCTAssertEqual(reader.speech.spokenLocation?.textRange?.quote, "sentence")
        XCTAssertEqual(reader.speech.spokenLocation?.textRange?.start, 6)
        engine.onRange?(NSRange(location: Int.max, length: Int.max))
        XCTAssertEqual(reader.speech.spokenLocation?.textRange?.quote, "sentence")
        reader.speech.pause()
        XCTAssertEqual(reader.speech.state, .paused)
        XCTAssertTrue(engine.paused)
        reader.speech.resume()
        XCTAssertEqual(reader.speech.state, .speaking)
        let second = expectation(description: "Second speech")
        engine.onSpeak = { text in
            XCTAssertEqual(text, "Second sentence.")
            second.fulfill()
        }
        engine.finish()
        await fulfillment(of: [second], timeout: 3)
        await reader.shutdown()
        XCTAssertEqual(reader.speech.state, .stopped)
        XCTAssertNil(engine.completion)
    }

    func testReplacingSpeechRejectsLateCallbacks() async throws {
        let engine = TestSpeechEngine()
        let reader = try await BookReader(
            book: makeTextBook("<p>Old sentence. New sentence.</p>"),
            configuration: .init(speechEngine: engine))
        reader.speech.followsText = false
        reader.speech.highlightsText = false
        let first = expectation(description: "First")
        engine.onSpeak = { _ in first.fulfill() }
        reader.speech.start()
        await fulfillment(of: [first], timeout: 3)
        let oldCallback = engine.onRange
        let result = try await reader.search("New sentence")
        let second = expectation(description: "Replacement")
        engine.onSpeak = { text in
            XCTAssertEqual(text, "New sentence.")
            second.fulfill()
        }
        reader.speech.start(from: reader.book.locator(for: result[0].position))
        await fulfillment(of: [second], timeout: 3)
        oldCallback?(NSRange(location: 0, length: 3))
        XCTAssertNil(reader.speech.spokenLocation)
        await reader.shutdown()
    }

    func testEngineFailureReachesReader() async throws {
        let engine = TestSpeechEngine()
        let reader = try await BookReader(
            book: makeTextBook("<p>One.</p>"), configuration: .init(speechEngine: engine))
        reader.speech.followsText = false
        reader.speech.highlightsText = false
        let failed = expectation(description: "Failure")
        let stream = reader.events
        let task = Task { @MainActor in
            for await event in stream {
                if case .error = event {
                    failed.fulfill()
                    return
                }
            }
        }
        engine.failure = .renderingFailed("Voice service unavailable")
        reader.speech.start()
        await fulfillment(of: [failed], timeout: 3)
        task.cancel()
        XCTAssertEqual(reader.lastError, engine.failure)
        if case .failed = reader.speech.state {} else { XCTFail("Expected failed speech state") }
        await reader.shutdown()
    }

    func testEmptyTextReportsFailureToReader() async throws {
        let reader = try await BookReader(book: makeTextBook("<img alt='Cover'>"), configuration: .init(speechEngine: TestSpeechEngine()))
        let failed = expectation(description: "No text error")
        let stream = reader.events
        let task = Task { @MainActor in
            for await event in stream {
                if case .error = event { failed.fulfill(); return }
            }
        }
        reader.speech.start()
        await fulfillment(of: [failed], timeout: 3)
        task.cancel()
        XCTAssertEqual(reader.lastError, .navigationFailed("No readable text is available"))
        await reader.shutdown()
    }

    func testSystemEngineRejectsMissingVoiceWithoutPlayingAudio() async throws {
        let engine = SystemReaderSpeechEngine()
        do {
            try await engine.speak(
                "Test", options: .init(voiceIdentifier: "bookkit.missing.voice", volume: 0)
            ) { _ in }
            XCTFail("Expected an unavailable voice error")
        } catch let error as BookError {
            XCTAssertEqual(error, .renderingFailed("The requested speech voice is unavailable"))
        }
    }
}

@MainActor
private final class TestSpeechEngine: ReaderSpeechEngine {
    var completion: CheckedContinuation<Void, Error>?
    var onRange: (@MainActor @Sendable (NSRange) -> Void)?
    var onSpeak: ((String) -> Void)?
    var options: SpeechOptions?
    var failure: BookError?
    var paused = false

    func speak(
        _ text: String, options: SpeechOptions,
        onRange: @escaping @MainActor @Sendable (NSRange) -> Void
    ) async throws {
        if let failure { throw failure }
        self.options = options
        self.onRange = onRange
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            onSpeak?(text)
        }
    }
    func pause() { paused = true }
    func resume() { paused = false }
    func stop() {
        let old = completion
        completion = nil
        old?.resume(throwing: CancellationError())
    }
    func finish() {
        let old = completion
        completion = nil
        old?.resume()
    }
}
