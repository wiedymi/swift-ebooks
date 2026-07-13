import Foundation

#if canImport(SwiftUI)
import SwiftUI

struct BookReaderAudioView: View {
    @ObservedObject var reader: BookReader
    @State private var isScrubbing = false
    @State private var scrubbedElapsed: Double = 0

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text(reader.book.metadata.title)
                    .font(.title2.weight(.semibold))
                Text(trackTitle)
                    .foregroundStyle(.secondary)
                Text("\(formatTime(displayedElapsed)) / \(formatTime(duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            #if os(tvOS)
            ProgressView(value: elapsed, total: max(duration, 1))
                .frame(maxWidth: 560)
                .accessibilityLabel("Playback position")
            #else
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubbedElapsed : elapsed },
                    set: { scrubbedElapsed = $0 }
                ),
                in: 0...max(duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        scrubbedElapsed = elapsed
                        isScrubbing = true
                    } else {
                        isScrubbing = false
                        let timestamp = clipBegin + scrubbedElapsed
                        reader.perform { try await $0.seek(toTimestamp: timestamp) }
                    }
                }
            )
            .frame(maxWidth: 560)
            .accessibilityLabel("Playback position")
            #endif

            HStack(spacing: 18) {
                Button {
                    reader.perform { try await $0.previous() }
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                Button {
                    reader.perform { try await $0.skip(by: -15) }
                } label: {
                    Image(systemName: "gobackward.15")
                }
                Button {
                    if reader.playback?.status == .playing {
                        reader.perform { try await $0.pause() }
                    } else {
                        reader.perform { try await $0.play() }
                    }
                } label: {
                    Image(
                        systemName: reader.playback?.status == .playing
                            ? "pause.circle.fill"
                            : "play.circle.fill"
                    )
                    .font(.system(size: 50))
                }
                Button {
                    reader.perform { try await $0.skip(by: 15) }
                } label: {
                    Image(systemName: "goforward.15")
                }
                Button {
                    reader.perform { try await $0.next() }
                } label: {
                    Image(systemName: "forward.end.fill")
                }
            }
            .buttonStyle(.plain)
            .font(.title2)

            Picker(
                "Speed",
                selection: Binding(
                    get: { Double(reader.playback?.rate ?? 1) },
                    set: { rate in
                        reader.perform { try $0.setPlaybackRate(Float(rate)) }
                    }
                )
            ) {
                ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                    Text("\(rate, specifier: "%g")×").tag(rate)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            ProgressView(value: reader.playback?.totalProgression ?? 0)
                .frame(maxWidth: 560)
                .accessibilityLabel("Book progress")
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chapter: Chapter? {
        guard reader.book.readingOrder.indices.contains(reader.position.spineIndex) else {
            return nil
        }
        return reader.book.readingOrder[reader.position.spineIndex]
    }

    private var trackTitle: String {
        chapter?.title ?? "Track \(reader.position.spineIndex + 1)"
    }

    private var clipBegin: Double {
        chapter?.audio?.clipBegin ?? 0
    }

    private var duration: Double {
        max(reader.playback?.trackDuration ?? 0, 0)
    }

    private var elapsed: Double {
        max((reader.playback?.position.timestamp ?? clipBegin) - clipBegin, 0)
    }

    private var displayedElapsed: Double {
        isScrubbing ? scrubbedElapsed : elapsed
    }

    private func formatTime(_ seconds: Double) -> String {
        let value = max(Int(seconds.rounded(.down)), 0)
        let hours = value / 3600
        let minutes = value % 3600 / 60
        let remainder = value % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
#endif
