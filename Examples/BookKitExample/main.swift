#if canImport(SwiftUI) && canImport(UniformTypeIdentifiers) && canImport(WebKit)
import BookKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

@main
struct BookKitExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ExampleRootView()
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

private struct ExampleLinkPolicy: LinkPolicy {
    func action(for url: URL, context _: LinkContext) async -> LinkAction {
        switch url.scheme?.lowercased() {
        case "http", "https": return .openExternally
        case "bookkit", nil: return .follow
        default: return .block
        }
    }
}

private struct ExampleRootView: View {
    @StateObject private var model = ExampleViewModel()

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .fileImporter(
            isPresented: $model.isImporterPresented,
            allowedContentTypes: ExampleViewModel.supportedTypes
        ) { model.handleImportResult($0) }
        .task {
            model.syncSystemAccessibility()
            model.openDemoFromArgumentsIfPresent()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: ExampleSystemAccessibility.primaryNotification
            )
        ) { _ in
            model.syncSystemAccessibility()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: ExampleSystemAccessibility.secondaryNotification
            )
        ) { _ in
            model.syncSystemAccessibility()
        }
    }

    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button("Open Book") {
                    model.isImporterPresented = true
                }
                .keyboardShortcut("o", modifiers: [.command])

                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }

                Divider().frame(height: 18)

                Button("Back", systemImage: "chevron.left") { model.goBack() }
                    .disabled(!model.canGoBack)
                Button("Forward", systemImage: "chevron.right") { model.goForward() }
                    .disabled(!model.canGoForward)
                Button("Previous", systemImage: "arrow.left.circle") { model.previous() }
                    .disabled(!model.canNavigate)
                Button("Next", systemImage: "arrow.right.circle") { model.next() }
                    .disabled(!model.canNavigate)

                Button("Flow: \(model.readingMode.title)", systemImage: "text.justify") {
                    model.toggleReadingMode()
                }
                .disabled(!model.canNavigate || model.reader?.isAudiobook == true)

                if model.reader?.supportsSpreads == true {
                    Toggle(
                        "Spread",
                        isOn: Binding(
                            get: { model.showsSpread },
                            set: { model.showsSpread = $0 }
                        )
                    )
                    .toggleStyle(.switch)
                }

                Toggle(
                    "VoiceOver",
                    isOn: Binding(
                        get: { model.isVoiceOverEnabled },
                        set: { model.setVoiceOverEnabledFromUI($0) }
                    )
                )
                .toggleStyle(.switch)

                Button("Copy Locator", systemImage: "doc.on.doc") {
                    model.copyCurrentLocator()
                }
                .disabled(!model.canNavigate)

                Button("Plug-in", systemImage: "puzzlepiece.extension") {
                    model.pingExamplePlugin()
                }
                .disabled(!model.canUsePlugin)
            }
            .buttonStyle(.bordered)
            .padding(10)
        }
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var content: some View {
        if let reader = model.reader {
            HStack(spacing: 0) {
                sidebar(reader: reader)
                    .frame(width: 320)
                Divider()
                BookReaderView(reader: reader, observesSystemAccessibility: false)
                    .selectionActions { selection in
                        HStack {
                            Button("Highlight") {
                                Task { @MainActor in
                                    do { _ = try await reader.highlightSelection() }
                                    catch { model.errorMessage = error.localizedDescription }
                                }
                            }
                            Button("Read aloud") { reader.speech.start(from: selection.locator) }
                            Button("Clear selection") {
                                Task { @MainActor in
                                    do { try await reader.clearSelection() }
                                    catch { model.errorMessage = error.localizedDescription }
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .padding()
                        .background(.regularMaterial)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 46))
                    .foregroundStyle(.secondary)
                Text("BookKit Example")
                    .font(.title2.weight(.semibold))
                Text("Open any supported DRM-free publication.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sidebar(reader: BookReader) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let poster = model.posterImage {
                    platformImageView(poster)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 200, maxHeight: 240)
                        .frame(maxWidth: .infinity)
                }

                Text(reader.book.metadata.title)
                    .font(.title3.weight(.semibold))
                Text(reader.book.metadata.authors.joined(separator: ", ").ifEmpty("Unknown author"))
                    .foregroundStyle(.secondary)

                Group {
                    Text("Format: \(reader.book.format.rawValue.uppercased())")
                    Text("Sections: \(reader.book.readingOrder.count)")
                    Text("Position: \(reader.position.spineIndex + 1) • \(Int(reader.position.progression * 100))%")
                    Text("Book progress: \(Int(reader.locator.totalProgression * 100))%")
                    Text("Measured pages: \(reader.pageCount)")
                    Text("Mode: \(model.readingMode.title) (effective: \(model.effectiveReadingMode.title))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !reader.book.readingOrder.isEmpty {
                    Picker(
                        "Section",
                        selection: Binding(
                            get: { reader.position.spineIndex },
                            set: { model.selectSection($0) }
                        )
                    ) {
                        ForEach(reader.book.readingOrder.indices, id: \.self) { index in
                            Text(sectionTitle(reader.book, index: index)).tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                }

                navigationGroup("Contents", nodes: reader.book.tableOfContents)
                navigationGroup("Landmarks", nodes: reader.book.landmarks)
                navigationGroup("Page List", nodes: reader.book.pageList)

                ReaderFeatureControls(reader: reader)
                    .id(reader.book.id)
                bookmarkSection(reader: reader)
                eventSection(reader: reader)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func navigationGroup(_ title: String, nodes: [TOCNode]) -> some View {
        if !nodes.isEmpty {
            DisclosureGroup(title) {
                ForEach(nodes.flatMap(\.flattened)) { item in
                    Button(item.title.ifEmpty("Untitled")) {
                        model.openNavigationItem(item)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
    }

    private func bookmarkSection(reader: BookReader) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bookmarks").font(.headline)
            HStack {
                TextField("Note", text: $model.bookmarkNoteDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { model.addBookmark() }
            }
            ForEach(reader.bookmarks) { bookmark in
                HStack {
                    Button(bookmarkLabel(bookmark)) {
                        model.openBookmark(bookmark)
                    }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                    Spacer()
                    Button("Delete") { model.removeBookmark(bookmark.id) }
                        .font(.caption2)
                }
                .font(.caption)
            }
        }
    }

    private func eventSection(reader: BookReader) -> some View {
        DisclosureGroup("Live events") {
            VStack(alignment: .leading, spacing: 5) {
                if let selection = reader.selection {
                    Text("Selection: \(selection.text)").lineLimit(3)
                }
                Text("Plug-in: \(model.pluginStatus)")
                ForEach(Array(model.eventLog.suffix(8).enumerated()), id: \.offset) { _, event in
                    Text(event)
                }
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ book: Book, index: Int) -> String {
        let title = book.readingOrder[index].title?.ifEmpty("Untitled") ?? "Untitled"
        return "\(index + 1). \(title)"
    }

    private func bookmarkLabel(_ bookmark: ReadingBookmark) -> String {
        let progress = Int(bookmark.position.progression * 100)
        let note = bookmark.note?.ifEmpty("") ?? ""
        return "\(bookmark.position.spineIndex + 1) • \(progress)%\(note.isEmpty ? "" : " • \(note)")"
    }

    private func platformImageView(_ image: PlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }
}

@MainActor
final class ExampleViewModel: ObservableObject {
    @Published var isImporterPresented = false
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published private(set) var reader: BookReader?
    @Published private(set) var posterImage: PlatformImage?
    @Published var bookmarkNoteDraft = ""
    @Published private(set) var eventLog: [String] = []
    @Published private(set) var pluginStatus = "Idle"
    @Published private(set) var isVoiceOverEnabled = false
    @Published private(set) var prefersReducedMotion = false

    var canNavigate: Bool { reader != nil }
    var canUsePlugin: Bool { reader != nil && reader?.isAudiobook == false }
    var canGoBack: Bool { reader?.canGoBack ?? false }
    var canGoForward: Bool { reader?.canGoForward ?? false }
    var readingMode: ReadingMode { reader?.preferences.readingMode ?? .scroll }
    var effectiveReadingMode: ReadingMode {
        isVoiceOverEnabled && reader?.accessibility.forceScrollWhenVoiceOverEnabled == true
            ? .scroll
            : readingMode
    }
    var showsSpread: Bool {
        get { reader?.showsSpread ?? false }
        set { reader?.showsSpread = newValue }
    }

    static var supportedTypes: [UTType] {
        let extensions = [
            "epub", "fb2", "zip", "mobi", "azw3", "kf8", "pdf", "cbz",
            "djvu", "djv", "txt", "html", "htm", "md", "markdown", "lpf",
            "audiobook", "mp3", "m4a", "m4b", "aac",
        ]
        return extensions.compactMap { UTType(filenameExtension: $0) }
    }

    private let openOptions = OpenOptions(allowsNetwork: false)
    private lazy var stateStore = FileReaderStateStore(directory: Self.readerStateDirectory())
    private var readerObservation: AnyCancellable?
    private var eventTask: Task<Void, Never>?
    private var didAttemptDemoOpen = false
    private var isAutomatedDemoLaunch = false

    func handleImportResult(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            Task { await openBook(at: url) }
        case let .failure(error):
            errorMessage = "File import failed: \(error.localizedDescription)"
        }
    }

    func openBook(at url: URL) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        if let reader {
            await reader.shutdown()
        }
        eventTask?.cancel()
        readerObservation?.cancel()

        do {
            let configuration = BookReader.Configuration(
                openOptions: openOptions,
                stateStore: stateStore,
                linkPolicy: ExampleLinkPolicy(),
                accessibility: accessibilitySettings,
                plugins: [Self.examplePlugin]
            )
            let reader = try await BookReader.open(from: url, configuration: configuration)
            self.reader = reader
            observe(reader)
            posterImage = await loadPosterImage(for: reader.book)
            appendEvent("Opened \(reader.book.format.rawValue.uppercased()) • \(reader.book.readingOrder.count) sections")

            if isAutomatedDemoLaunch {
                print(
                    "BOOKKIT_EXAMPLE_READY format=\(reader.book.format.rawValue) "
                        + "chapters=\(reader.book.readingOrder.count) "
                        + "toc=\(reader.book.tableOfContents.flatMap(\.flattened).count)"
                )
            }
        } catch {
            reader = nil
            posterImage = nil
            errorMessage = "Open failed: \(error.localizedDescription)"
            if isAutomatedDemoLaunch {
                print("BOOKKIT_EXAMPLE_FAILED \(error.localizedDescription)")
            }
        }
    }

    func next() {
        perform("Next failed") { try await $0.next() }
    }

    func previous() {
        perform("Previous failed") { try await $0.previous() }
    }

    func goBack() {
        perform("Back failed") { _ = try await $0.goBack() }
    }

    func goForward() {
        perform("Forward failed") { _ = try await $0.goForward() }
    }

    func selectSection(_ index: Int) {
        perform("Navigation failed") {
            try await $0.go(to: Position(spineIndex: index, progression: 0))
        }
    }

    func openNavigationItem(_ item: TOCNode) {
        perform("Navigation failed") { try await $0.go(to: item) }
    }

    func openBookmark(_ bookmark: ReadingBookmark) {
        perform("Bookmark navigation failed") { try await $0.go(to: bookmark.position) }
    }

    func addBookmark() {
        let note = bookmarkNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        perform("Bookmark failed") {
            _ = try await $0.addBookmark(note: note.isEmpty ? nil : note)
        }
        bookmarkNoteDraft = ""
    }

    func removeBookmark(_ id: UUID) {
        perform("Bookmark removal failed") { try await $0.removeBookmark(id: id) }
    }

    func toggleReadingMode() {
        let next: ReadingMode = readingMode == .scroll ? .paginated : .scroll
        perform("Reading mode failed") { try await $0.setReadingMode(next) }
    }

    func pingExamplePlugin() {
        perform("Plug-in call failed") { reader in
            let reply = try await reader.callBridgeCommand(
                "example.ping",
                payload: .object(["message": .string("Hello from the app")])
            )
            self.pluginStatus = Self.describe(reply)
        }
    }

    func copyCurrentLocator() {
        guard let reader,
              let data = try? JSONEncoder().encode(reader.locator),
              let value = String(data: data, encoding: .utf8)
        else {
            return
        }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #else
        UIPasteboard.general.string = value
        #endif
        appendEvent("Copied locator")
    }

    func syncSystemAccessibility() {
        isVoiceOverEnabled = ExampleSystemAccessibility.isVoiceOverEnabled
        prefersReducedMotion = ExampleSystemAccessibility.prefersReducedMotion
        applyAccessibility()
    }

    func setVoiceOverEnabledFromUI(_ enabled: Bool) {
        isVoiceOverEnabled = enabled
        applyAccessibility()
    }

    func openDemoFromArgumentsIfPresent() {
        guard !didAttemptDemoOpen else { return }
        didAttemptDemoOpen = true
        let arguments = CommandLine.arguments
        guard let marker = arguments.firstIndex(of: "--demo"), arguments.indices.contains(marker + 1) else {
            return
        }
        isAutomatedDemoLaunch = true
        let value = arguments[marker + 1]
        let url = URL(string: value).flatMap { $0.scheme == nil ? nil : $0 }
            ?? URL(fileURLWithPath: value)
        Task { await openBook(at: url) }
    }

    private var accessibilitySettings: ReaderAccessibilitySettings {
        ReaderAccessibilitySettings(
            isVoiceOverEnabled: isVoiceOverEnabled,
            forceScrollWhenVoiceOverEnabled: true,
            prefersReducedMotion: prefersReducedMotion,
            announcesPositionChanges: isVoiceOverEnabled
        )
    }

    private func applyAccessibility() {
        guard reader != nil else { return }
        let settings = accessibilitySettings
        perform("Accessibility update failed") { try await $0.setAccessibility(settings) }
    }

    private func perform(
        _ failurePrefix: String,
        operation: @escaping @MainActor (BookReader) async throws -> Void
    ) {
        guard let reader else { return }
        Task { @MainActor [weak self, weak reader] in
            guard let self, let reader else { return }
            do {
                try await operation(reader)
            } catch {
                errorMessage = "\(failurePrefix): \(error.localizedDescription)"
            }
        }
    }

    private func observe(_ reader: BookReader) {
        readerObservation = reader.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }

        let events = reader.events
        eventTask = Task { @MainActor [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: BookReaderEvent) {
        switch event {
        case .ready:
            appendEvent("Reader ready")
        case let .selectionChanged(selection):
            appendEvent("Selected \(selection.text.prefix(36))")
        case let .linkActivated(url, kind, action):
            appendEvent("Link \(kind.rawValue): \(action) • \(url.absoluteString)")
            if action == .openExternally {
                Self.openExternally(url)
            }
        case let .decorationTapped(value):
            appendEvent("Decoration: \(value.group.rawValue)/\(value.id)")
        case let .bridgeMessage(name, payload):
            pluginStatus = "\(name): \(Self.describe(payload))"
            appendEvent("Plug-in event: \(name)")
        case let .playbackTrackChanged(index, title):
            appendEvent("Track \(index + 1): \(title ?? "Untitled")")
        case .playbackEnded:
            appendEvent("Audiobook ended")
        case let .error(error):
            errorMessage = error.localizedDescription
            appendEvent("Reader error")
        default:
            break
        }
    }

    private func loadPosterImage(for book: Book) async -> PlatformImage? {
        let loader = ResourceLoader(book: book, options: openOptions)
        let candidates = book.assets
            .filter { $0.mediaType.lowercased().hasPrefix("image/") }
            .sorted { Self.posterScore($0) > Self.posterScore($1) }

        for asset in candidates {
            if let data = try? await loader.data(forAssetID: asset.id),
               let image = PlatformImage(data: data)
            {
                return image
            }
        }
        return nil
    }

    private func appendEvent(_ value: String) {
        eventLog.append(value)
        if eventLog.count > 50 {
            eventLog.removeFirst(eventLog.count - 50)
        }
    }

    private static func posterScore(_ asset: Asset) -> Int {
        let key = "\(asset.id.lowercased()) \(asset.href.lowercased())"
        return (key.contains("cover") ? 100 : 0)
            + (key.contains("poster") ? 80 : 0)
            + (asset.mediaType.lowercased() == "image/jpeg" ? 10 : 0)
    }

    private static func readerStateDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("BookKitExample/ReaderState", isDirectory: true)
    }

    private static func describe(_ value: BridgeValue) -> String {
        switch value {
        case .null: return "null"
        case let .bool(value): return String(value)
        case let .number(value): return String(value)
        case let .string(value): return value
        case let .array(values): return "[\(values.map(describe).joined(separator: ", "))]"
        case let .object(values):
            return "{" + values.keys.sorted().map { key in
                "\(key): \(describe(values[key] ?? .null))"
            }.joined(separator: ", ") + "}"
        }
    }

    private static func openExternally(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    private static let examplePlugin = ReflowScriptPlugin(
        identifier: "bookkit.example.integration",
        source: """
        window.BookKit.registerCommand('example.ping', payload => ({
          reply: 'pong',
          received: payload
        }));
        window.BookKit.on('contentDidChange', context => {
          window.BookKit.post('example.contentReady', context);
        });
        """
    )

    isolated deinit {
        readerObservation?.cancel()
        eventTask?.cancel()
    }
}

@MainActor
private enum ExampleSystemAccessibility {
    #if os(macOS)
    static var isVoiceOverEnabled: Bool { NSWorkspace.shared.isVoiceOverEnabled }
    static var prefersReducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let primaryNotification = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
    static let secondaryNotification = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
    #else
    static var isVoiceOverEnabled: Bool { UIAccessibility.isVoiceOverRunning }
    static var prefersReducedMotion: Bool { UIAccessibility.isReduceMotionEnabled }
    static let primaryNotification = UIAccessibility.voiceOverStatusDidChangeNotification
    static let secondaryNotification = UIAccessibility.reduceMotionStatusDidChangeNotification
    #endif
}

private extension ReadingMode {
    var title: String {
        switch self {
        case .scroll: "Scroll"
        case .paginated: "Pages"
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

#else
import Foundation

@main
struct BookKitExampleApp {
    static func main() {
        print("BookKitExample requires SwiftUI + WebKit on an Apple platform.")
    }
}
#endif
