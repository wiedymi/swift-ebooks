import AVFoundation
import Combine
import Foundation

public struct SpeechOptions: Sendable, Equatable {
    public var voiceIdentifier: String?
    public var language: String?
    /// Uses the selected engine’s rate scale. The default is the system speech rate.
    /// A custom engine defines its supported values and clamps or rejects invalid input.
    public var rate: Float
    public var pitch: Float
    public var volume: Float

    public init(
        voiceIdentifier: String? = nil, language: String? = nil,
        rate: Float = AVSpeechUtteranceDefaultSpeechRate, pitch: Float = 1, volume: Float = 1
    ) {
        self.voiceIdentifier = voiceIdentifier
        self.language = language
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
    }
}

/// Implement this protocol to use a custom voice or prerecorded speech.
/// Each call finishes when playback ends. Stop and task cancellation must end the call.
/// Range callbacks use UTF-16 offsets in `text` and must stop when the call ends.
@MainActor
public protocol ReaderSpeechEngine: AnyObject {
    func speak(
        _ text: String, options: SpeechOptions,
        onRange: @escaping @MainActor @Sendable (NSRange) -> Void) async throws
    func pause()
    func resume()
    func stop()
}

public enum ReaderSpeechState: Sendable, Equatable {
    case stopped
    case loading
    case speaking
    case paused
    case finished
    case failed(BookError)
}

/// Controls reading aloud. VoiceOver remains the system screen reader.
@MainActor
public final class ReaderSpeechController: ObservableObject {
    @Published public private(set) var state: ReaderSpeechState = .stopped
    @Published public private(set) var currentText: ReadingText?
    /// The word or phrase currently being spoken, when the engine reports it.
    @Published public private(set) var spokenLocation: Locator?
    public var highlightStyle: DecorationStyle = .default(for: .tts)
    public var highlightsText = true
    public var followsText = true
    public var continuesAcrossSections = true

    private weak var reader: BookReader?
    private let engine: any ReaderSpeechEngine
    private var task: Task<Void, Never>?
    private var activeID: UUID?
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    init(reader: BookReader, engine: any ReaderSpeechEngine) {
        self.reader = reader
        self.engine = engine
    }

    isolated deinit {
        task?.cancel()
        engine.stop()
    }

    /// Starts at the supplied location, current selection, or current reading position.
    public func start(from location: Locator? = nil, options: SpeechOptions = .init()) {
        stop()
        guard let reader else { return }
        let start = location ?? reader.selection?.locator ?? reader.locator
        let book = reader.book
        guard book.readingOrder.indices.contains(start.sectionIndex), !reader.isAudiobook else {
            fail(BookError.navigationFailed("No readable text is available"))
            return
        }
        let id = UUID()
        activeID = id
        state = .loading
        var options = options
        if options.language == nil { options.language = book.metadata.language }
        let speechOptions = options
        let previous = task
        task = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try Task.checkCancellation()
                let lastSection =
                    self?.continuesAcrossSections == true ? book.readingOrder.count : start.sectionIndex + 1
                var hasText = false
                for section in start.sectionIndex..<lastSection {
                    try Task.checkCancellation()
                    let parts = try await book.readingText(inSection: section)
                    hasText = hasText || !parts.isEmpty
                    var startOffset: Int?
                    if section == start.sectionIndex, let range = start.textRange {
                        guard let resolved = NormalizedText(parts.map(\.text).joined()).resolve(range) else {
                            throw BookError.navigationFailed("The speech text location could not be found")
                        }
                        startOffset = resolved.location
                    }
                    for part in parts {
                        try Task.checkCancellation()
                        guard let self, self.activeID == id else { return }
                        if section == start.sectionIndex {
                            let end = part.locator.textRange?.end ?? 0
                            if let startOffset {
                                if end <= startOffset { continue }
                            } else {
                                let length = max(parts.last?.locator.textRange?.end ?? 1, 1)
                                if Double(end) / Double(length) <= start.sectionProgression { continue }
                            }
                        }
                        if self.state == .paused {
                            await withCheckedContinuation { self.resumeWaiter = $0 }
                            try Task.checkCancellation()
                        }
                        self.currentText = part
                        if self.highlightsText, self.reader?.capabilities.contains(.textDecorations) == true {
                            try await self.reader?.showSpokenText(
                                part.locator, style: self.highlightStyle, followsText: self.followsText)
                        } else if self.followsText {
                            try await self.reader?.followText(part.locator)
                        }
                        try Task.checkCancellation()
                        if self.state == .paused {
                            await withCheckedContinuation { self.resumeWaiter = $0 }
                            try Task.checkCancellation()
                        }
                        self.state = .speaking
                        try await self.engine.speak(part.text, options: speechOptions) { [weak self] range in
                            guard let self, self.activeID == id,
                                range.location >= 0, range.length > 0,
                                range.location <= part.text.utf16.count,
                                range.length <= part.text.utf16.count - range.location,
                                Range(range, in: part.text) != nil,
                                let base = part.locator.textRange
                            else { return }
                            let local = BookText.range(in: part.text, range: range)
                            var locator = part.locator
                            locator.textRange = ReaderTextRange(
                                start: base.start + local.start, end: base.start + local.end,
                                quote: local.quote, prefix: String((base.prefix + local.prefix).suffix(32)),
                                suffix: String((local.suffix + base.suffix).prefix(32)))
                            self.spokenLocation = locator
                        }
                    }
                }
                guard let self, self.activeID == id else { return }
                if hasText {
                    self.state = .finished
                    self.activeID = nil
                } else {
                    self.fail(BookError.navigationFailed("No readable text is available"))
                }
                try await self.reader?.clearDecorations(in: .tts)
            } catch is CancellationError {
                if let self, self.activeID == id {
                    self.activeID = nil
                    self.state = .stopped
                    self.currentText = nil
                    self.spokenLocation = nil
                    try? await self.reader?.clearDecorations(in: .tts)
                }
            } catch {
                guard let self, self.activeID == id else { return }
                self.fail(error)
                try? await self.reader?.clearDecorations(in: .tts)
            }
        }
    }

    public func pause() {
        guard state == .speaking else { return }
        engine.pause()
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        engine.resume()
        state = .speaking
        resumeWaiter?.resume()
        resumeWaiter = nil
    }

    public func stop() {
        activeID = nil
        let previous = task
        previous?.cancel()
        resumeWaiter?.resume()
        resumeWaiter = nil
        engine.stop()
        state = .stopped
        currentText = nil
        spokenLocation = nil
        task = Task { @MainActor [weak reader] in
            await previous?.value
            do { try await reader?.clearDecorations(in: .tts) } catch { reader?.report(error) }
        }
    }

    func shutdown() async {
        stop()
        await task?.value
    }

    private func fail(_ error: Error) {
        let error = BookError.from(error)
        activeID = nil
        engine.stop()
        state = .failed(error)
        reader?.report(error)
    }
}

extension BookReader {
    /// Lazily creates a speech controller for this session.
    public var speech: ReaderSpeechController {
        if let speechController { return speechController }
        let controller = ReaderSpeechController(
            reader: self, engine: configuredSpeechEngine ?? SystemReaderSpeechEngine())
        speechController = controller
        return controller
    }

    /// Displays a speech or dubbing cue supplied by the app.
    public func showSpokenText(
        _ locator: Locator, style: DecorationStyle = .default(for: .tts), followsText: Bool = true
    ) async throws {
        if followsText { try await followText(locator) }
        try await setDecorations(
            [Decoration(id: "bookkit-speech", group: .tts, locator: locator, style: style)], in: .tts)
    }

    internal func followText(_ locator: Locator) async throws {
        try await renderer.followText(locator)
        await refreshState()
    }
}
