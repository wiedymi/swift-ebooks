import AVFoundation
import Foundation

/// Apple's installed voices. Each engine belongs to one reader session.
@MainActor
public final class SystemReaderSpeechEngine: NSObject, ReaderSpeechEngine, AVSpeechSynthesizerDelegate {
    private struct Pending {
        let utterance: IdentifiedUtterance
        let completion: CheckedContinuation<Void, Error>
        let onRange: @MainActor @Sendable (NSRange) -> Void
    }

    public static var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var pending: Pending?

    /// Keep `usesApplicationAudioSession` true when the app manages background audio.
    public init(usesApplicationAudioSession: Bool = true) {
        super.init()
        synthesizer.delegate = self
        #if !os(macOS)
            synthesizer.usesApplicationAudioSession = usesApplicationAudioSession
        #endif
    }

    public func speak(
        _ text: String, options: SpeechOptions,
        onRange: @escaping @MainActor @Sendable (NSRange) -> Void
    ) async throws {
        stop()
        try Task.checkCancellation()
        guard !text.isEmpty else { return }
        let utterance = IdentifiedUtterance(string: text)
        let id = utterance.id
        if let identifier = options.voiceIdentifier {
            guard let voice = AVSpeechSynthesisVoice(identifier: identifier) else {
                throw BookError.speechVoiceUnavailable(identifier)
            }
            utterance.voice = voice
        } else if let language = options.language {
            guard let voice = AVSpeechSynthesisVoice(language: language) else {
                throw BookError.speechLanguageUnavailable(language)
            }
            utterance.voice = voice
        }
        utterance.rate =
            options.rate.isFinite
            ? min(max(options.rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
            : AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = options.pitch.isFinite ? min(max(options.pitch, 0.5), 2) : 1
        utterance.volume = options.volume.isFinite ? min(max(options.volume, 0), 1) : 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = Pending(utterance: utterance, completion: continuation, onRange: onRange)
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pending?.utterance.id == id else { return }
                self?.stop()
            }
        }
    }

    public func pause() { synthesizer.pauseSpeaking(at: .immediate) }
    public func resume() { synthesizer.continueSpeaking() }

    public func stop() {
        let previous = pending
        pending = nil
        synthesizer.stopSpeaking(at: .immediate)
        previous?.completion.resume(throwing: CancellationError())
    }

    public nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        guard let id = (utterance as? IdentifiedUtterance)?.id else { return }
        Task { @MainActor [weak self] in
            guard let self, self.pending?.utterance.id == id else { return }
            let completion = self.pending?.completion
            self.pending = nil
            completion?.resume()
        }
    }

    public nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        guard let id = (utterance as? IdentifiedUtterance)?.id else { return }
        Task { @MainActor [weak self] in
            guard self?.pending?.utterance.id == id else { return }
            self?.stop()
        }
    }

    public nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard let id = (utterance as? IdentifiedUtterance)?.id else { return }
        Task { @MainActor [weak self] in
            guard let pending = self?.pending, pending.utterance.id == id else { return }
            pending.onRange(range)
        }
    }
}

// The immutable ID can cross the delegate boundary without transferring the utterance.
private final class IdentifiedUtterance: AVSpeechUtterance {
    let id = UUID()
}
