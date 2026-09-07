#if canImport(SwiftUI)
    import BookKit
    import SwiftUI

    struct ReaderFeatureControls: View {
        @ObservedObject var reader: BookReader
        @State private var query = ""
        @State private var search: SearchState = .idle
        @State private var actionError: String?

        private enum SearchState {
            case idle
            case loading
            case results([SearchResult])
            case failed(String)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                if reader.capabilities.contains(.search) {
                    TextField("Search text", text: $query)
                        switch search {
                    case .idle: EmptyView()
                    case .loading: ProgressView()
                    case .failed(let message): Text(message).foregroundStyle(.red)
                    case .results(let results):
                        Text("\(results.count) matches").font(.caption)
                        ForEach(results, id: \.position) { result in
                            Button(result.snippet) {
                                perform {
                                    try await reader.go(to: result.position)
                                    if reader.capabilities.contains(.textDecorations) {
                                        try await reader.setDecorations(
                                            [
                                                Decoration(
                                                    id: "active-search", group: .search,
                                                    locator: reader.book.locator(for: result.position))
                                            ], in: .search)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .lineLimit(2)
                            .font(.caption)
                        }
                    }
                }
                if reader.capabilities.contains(.speech) {
                    SpeechControls(speech: reader.speech)
                }
                let highlights = reader.decorations.filter { $0.group == .highlight }
                if !highlights.isEmpty {
                    Text("Highlights").font(.headline)
                    ForEach(highlights) { mark in
                        HStack {
                            Button(mark.locator.textRange?.quote ?? "Highlight") {
                                perform { try await reader.go(to: mark.locator) }
                            }
                            .lineLimit(2)
                            Spacer()
                            Button("Delete", systemImage: "trash") {
                                perform {
                                    try await reader.setDecorations(
                                        highlights.filter { $0.id != mark.id }, in: .highlight)
                                }
                            }
                            .labelStyle(.iconOnly)
                        }
                        .font(.caption)
                    }
                }
                if let actionError { Text(actionError).font(.caption).foregroundStyle(.red) }
            }
            .task(id: query) {
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    search = .idle
                    return
                }
                search = .loading
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    let results = try await reader.search(query, options: .init(maximumResults: 100))
                    try Task.checkCancellation()
                    search = .results(results)
                } catch is CancellationError {
                } catch {
                    search = .failed(error.localizedDescription)
                }
            }
        }

        private func perform(_ action: @escaping @MainActor () async throws -> Void) {
            Task { @MainActor in
                do {
                    try await action()
                    actionError = nil
                } catch { actionError = error.localizedDescription }
            }
        }
    }

    private struct SpeechControls: View {
        @ObservedObject var speech: ReaderSpeechController

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    switch speech.state {
                    case .loading: ProgressView()
                    case .speaking: Button("Pause speech") { speech.pause() }
                    case .paused: Button("Resume speech") { speech.resume() }
                    default: Button("Read aloud") { speech.start() }
                    }
                    Button("Stop speech") { speech.stop() }
                }
                if let text = speech.currentText { Text(text.text).font(.caption).lineLimit(2) }
                if case .failed(let error) = speech.state {
                    Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }
#endif
