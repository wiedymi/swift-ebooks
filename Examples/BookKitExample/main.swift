#if canImport(SwiftUI) && canImport(UniformTypeIdentifiers) && canImport(WebKit)
import BookKit
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
                .frame(minWidth: 1000, minHeight: 640)
        }
    }
}

private extension ReadingMode {
    static var exampleAllCases: [ReadingMode] {
        [.scroll, .paginated]
    }

    var title: String {
        switch self {
        case .scroll: return "Scroll"
        case .paginated: return "Pages"
        }
    }
}

struct ExampleRootView: View {
    @StateObject private var model = ExampleViewModel()
    @State private var controlsOffset: CGSize = .zero
    @GestureState private var controlsDragOffset: CGSize = .zero
    @State private var glassTintStrength: Double = 0.12

    var body: some View {
        ZStack(alignment: .top) {
            content

            floatingControls
                .padding(.top, 10)
                .offset(
                    x: controlsOffset.width + controlsDragOffset.width,
                    y: controlsOffset.height + controlsDragOffset.height
                )
        }
        .background(backgroundFill)
        .fileImporter(
            isPresented: $model.isImporterPresented,
            allowedContentTypes: ExampleViewModel.supportedTypes
        ) { result in
            model.handleImportResult(result)
        }
    }

    private var floatingControls: some View {
        VStack(spacing: 8) {
            dragHandle
            controlsRow
            blurRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 1220)
        .exampleGlassSurface(cornerRadius: 24, tintOpacity: glassTintStrength)
        .shadow(color: .black.opacity(0.14), radius: 20, y: 12)
        .padding(.horizontal, 12)
    }

    private var dragHandle: some View {
        Capsule(style: .continuous)
            .fill(Color.secondary.opacity(0.45))
            .frame(width: 48, height: 6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .updating($controlsDragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        controlsOffset.width += value.translation.width
                        controlsOffset.height += value.translation.height
                    }
            )
    }

    private var controlsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
            Button("Open Book") {
                model.isImporterPresented = true
            }
            .exampleControlButtonStyle()
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

            Spacer()

            Toggle(
                "VoiceOver",
                isOn: Binding(
                    get: { model.isVoiceOverEnabled },
                    set: { model.setVoiceOverEnabledFromUI($0) }
                )
            )
            .font(.caption)
            .toggleStyle(.switch)

            Button {
                model.toggleReadingMode()
            } label: {
                Label("Flow: \(model.readingMode.title)", systemImage: "text.justify")
            }
            .exampleControlButtonStyle()

            Button {
                model.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .exampleControlButtonStyle()
            .disabled(!model.canGoBack)

            Button {
                model.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .exampleControlButtonStyle()
            .disabled(!model.canGoForward)

            Button {
                model.previousPage()
            } label: {
                Label("Prev", systemImage: "arrow.left.circle")
            }
            .exampleControlButtonStyle()
            .disabled(!model.canNavigate)

            Button {
                model.nextPage()
            } label: {
                Label("Next", systemImage: "arrow.right.circle")
            }
            .exampleControlButtonStyle()
            .disabled(!model.canNavigate)

            Button {
                model.copyCurrentLocator()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .exampleControlButtonStyle()
            .disabled(!model.canNavigate)
        }
            .padding(.horizontal, 2)
        }
    }

    private var blurRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "drop.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Glass")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $glassTintStrength, in: 0...0.35)
                .frame(width: 170)
        }
        .padding(.horizontal, 4)
    }

    private var backgroundFill: some View {
        LinearGradient(
            colors: [
                Color(red: 0.95, green: 0.97, blue: 1.0),
                Color(red: 0.9, green: 0.94, blue: 0.98),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        if let book = model.book {
            HStack(spacing: 0) {
                infoPanel(book: book)
                    .frame(width: 330)
                Divider()
                readerPanel(book: book)
            }
        } else {
            VStack(spacing: 10) {
                Text("BookKit Example")
                    .font(.title2.weight(.semibold))
                Text("Open an EPUB, FB2, MOBI, AZW3/KF8, or PDF file.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func infoPanel(book: Book) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let posterImage = model.posterImage {
                    platformImageView(posterImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 220, maxHeight: 280)
                        .frame(maxWidth: .infinity)
                }

                Text(book.metadata.title)
                    .font(.title3.weight(.semibold))

                Text(book.metadata.authors.joined(separator: ", ").ifEmpty("Unknown author"))
                    .foregroundStyle(.secondary)

                Group {
                    Text("Format: \(book.format.rawValue.uppercased())")
                    Text("Chapters/Pages: \(book.readingOrder.count)")
                    Text("Assets: \(book.assets.count)")
                    Text("Position: \(model.position.spineIndex + 1) • \(Int(model.position.progression * 100))%")
                    Text("Locator: \(model.locator.sectionIndex + 1) • \(Int(model.locator.sectionProgression * 100))%")
                    Text("Book Progress: \(Int(model.locator.totalProgression * 100))%")
                    Text("Mode: \(model.readingMode.title) (effective: \(model.effectiveReadingMode.title))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if model.isVoiceOverEnabled, model.readingMode == .paginated, model.effectiveReadingMode == .scroll {
                    Text("VoiceOver is enabled, so effective mode is Scroll.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !book.readingOrder.isEmpty {
                    Picker("Chapter", selection: $model.selectedChapterIndex) {
                        ForEach(Array(book.readingOrder.indices), id: \.self) { index in
                            let title = book.readingOrder[index].title?.ifEmpty("Untitled \(index + 1)") ?? "Untitled \(index + 1)"
                            Text("\(index + 1). \(title)").tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: model.selectedChapterIndex) { newValue in
                        model.selectChapter(newValue)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Bookmarks")
                        .font(.headline)

                    HStack(spacing: 8) {
                        TextField("Bookmark note", text: $model.bookmarkNoteDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            model.addBookmark()
                        }
                        .disabled(!model.canNavigate)
                    }

                    if model.bookmarks.isEmpty {
                        Text("No bookmarks yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.bookmarks) { bookmark in
                            HStack(spacing: 8) {
                                Button {
                                    model.openBookmark(bookmark)
                                } label: {
                                    Text(bookmarkLabel(bookmark))
                                        .lineLimit(1)
                                        .font(.caption)
                                }

                                Spacer()

                                Button("Delete") {
                                    model.removeBookmark(bookmark.id)
                                }
                                .font(.caption2)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func readerPanel(book: Book) -> some View {
        if book.format == .pdf {
            ScrollView {
                Text(model.currentPDFPageText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let bridge = model.bridge {
            GeometryReader { geometry in
                BookView(bridge: bridge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        model.updateViewport(size: geometry.size)
                    }
                    .onChange(of: geometry.size) { newSize in
                        model.updateViewport(size: newSize)
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 24)
                            .onEnded { value in
                                model.handleSwipe(value)
                            }
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Reader unavailable for this format.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bookmarkLabel(_ bookmark: ReadingBookmark) -> String {
        let chapter = bookmark.position.spineIndex + 1
        let progress = Int(bookmark.position.progression * 100)
        let note = bookmark.note?.ifEmpty("")
        if let note, !note.isEmpty {
            return "Ch \(chapter) • \(progress)% • \(note)"
        }
        return "Ch \(chapter) • \(progress)%"
    }

    private func platformImageView(_ image: PlatformImage) -> Image {
        #if os(macOS)
        return Image(nsImage: image)
        #else
        return Image(uiImage: image)
        #endif
    }
}

@MainActor
final class ExampleViewModel: ObservableObject {
    @Published var isImporterPresented = false
    @Published var isBusy = false
    @Published var errorMessage: String?

    @Published var book: Book?
    @Published var renderer: ContentRenderer?
    @Published var bridge: WebViewReflowBridge?
    @Published var posterImage: PlatformImage?

    @Published var position: Position = .start
    @Published var locator: Locator = .start
    @Published var bookmarks: [ReadingBookmark] = []
    @Published var selectedChapterIndex: Int = 0
    @Published var bookmarkNoteDraft = ""
    @Published var readingMode: ReadingMode = .scroll
    @Published var effectiveReadingMode: ReadingMode = .scroll
    @Published var isVoiceOverEnabled = false
    @Published var canGoBack = false
    @Published var canGoForward = false

    @Published private var viewport = Viewport(width: 740, height: 900)

    var canNavigate: Bool { renderer != nil }

    private var positionPollTask: Task<Void, Never>?

    var currentPDFPageText: String {
        guard let book, book.format == .pdf, !book.readingOrder.isEmpty else {
            return "No PDF content available."
        }
        let idx = min(max(selectedChapterIndex, 0), book.readingOrder.count - 1)
        return book.readingOrder[idx].content
    }

    private let openOptions = OpenOptions(allowsNetwork: false, tempDirectory: nil, fileAccess: SandboxFileAccessPolicy())

    private lazy var stateStore: FileReaderStateStore = {
        FileReaderStateStore(directory: Self.readerStateDirectory())
    }()

    static var supportedTypes: [UTType] {
        var types: [UTType] = []
        for ext in ["epub", "fb2", "mobi", "azw3", "kf8", "pdf"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    func handleImportResult(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            Task {
                await openBook(at: url)
            }
        case let .failure(error):
            errorMessage = "File import failed: \(error.localizedDescription)"
        }
    }

    func openBook(at url: URL) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        positionPollTask?.cancel()

        do {
            let loadedBook = try await Book.open(from: url, options: openOptions)
            let bridge = loadedBook.format == .pdf ? nil : WebViewReflowBridge()
            let renderer = try ContentRenderer(
                book: loadedBook,
                options: openOptions,
                stateStore: stateStore,
                reflowBridge: bridge
            )

            self.book = loadedBook
            self.bridge = bridge
            self.renderer = renderer
            self.posterImage = try await loadPosterImage(for: loadedBook)

            try await renderer.restoreState()
            let restoredPreferences = await renderer.preferences()
            readingMode = restoredPreferences.readingMode
            let restoredPosition = await renderer.currentPosition()
            selectedChapterIndex = clampChapterIndex(restoredPosition.spineIndex, book: loadedBook)

            try await renderer.setAccessibility(
                ReaderAccessibilitySettings(
                    isVoiceOverEnabled: isVoiceOverEnabled,
                    forceScrollWhenVoiceOverEnabled: true
                )
            )

            if !loadedBook.readingOrder.isEmpty {
                try await renderer.renderChapter(
                    at: selectedChapterIndex,
                    viewport: viewport,
                    theme: restoredPreferences.theme,
                    typography: restoredPreferences.typography
                )
                if restoredPosition.progression > 0 {
                    try await renderer.go(to: restoredPosition)
                }
            }

            await refreshState()
            startPositionPolling()
        } catch {
            errorMessage = "Open failed: \(error.localizedDescription)"
        }
    }

    func updateViewport(size: CGSize) {
        guard size.width > 1, size.height > 1 else {
            return
        }

        let next = Viewport(width: size.width, height: size.height)
        if abs(next.width - viewport.width) < 1, abs(next.height - viewport.height) < 1 {
            return
        }

        viewport = next
        guard let renderer, let book, book.format != .pdf, !book.readingOrder.isEmpty else {
            return
        }

        Task {
            do {
                let preferences = await renderer.preferences()
                try await renderer.renderChapter(
                    at: selectedChapterIndex,
                    viewport: viewport,
                    theme: preferences.theme,
                    typography: preferences.typography
                )
                let restoredPosition = await renderer.currentPosition()
                try await renderer.go(to: restoredPosition)
                await refreshState()
            } catch {
                errorMessage = "Rerender failed: \(error.localizedDescription)"
            }
        }
    }

    func selectChapter(_ index: Int) {
        guard let renderer, let book else {
            return
        }
        let target = clampChapterIndex(index, book: book)

        Task {
            do {
                let preferences = await renderer.preferences()
                try await renderer.renderChapter(
                    at: target,
                    viewport: viewport,
                    theme: preferences.theme,
                    typography: preferences.typography
                )
                selectedChapterIndex = target
                await refreshState()
            } catch {
                errorMessage = "Chapter render failed: \(error.localizedDescription)"
            }
        }
    }

    func nextPage() {
        guard let renderer else { return }
        Task {
            do {
                try await renderer.nextPage()
                await refreshState()
            } catch {
                errorMessage = "Next page failed: \(error.localizedDescription)"
            }
        }
    }

    func previousPage() {
        guard let renderer else { return }
        Task {
            do {
                try await renderer.previousPage()
                await refreshState()
            } catch {
                errorMessage = "Previous page failed: \(error.localizedDescription)"
            }
        }
    }

    func goBack() {
        guard let renderer, renderer.canGoBack() else { return }
        Task {
            do {
                _ = try await renderer.goBack()
                await refreshState()
            } catch {
                errorMessage = "Back failed: \(error.localizedDescription)"
            }
        }
    }

    func goForward() {
        guard let renderer, renderer.canGoForward() else { return }
        Task {
            do {
                _ = try await renderer.goForward()
                await refreshState()
            } catch {
                errorMessage = "Forward failed: \(error.localizedDescription)"
            }
        }
    }

    func setReadingModeFromUI(_ mode: ReadingMode) {
        readingMode = mode
        guard let renderer else { return }
        Task {
            do {
                try await renderer.setReadingMode(mode)
                await refreshState()
            } catch {
                errorMessage = "Reading mode update failed: \(error.localizedDescription)"
            }
        }
    }

    func toggleReadingMode() {
        let next: ReadingMode = readingMode == .scroll ? .paginated : .scroll
        setReadingModeFromUI(next)
    }

    func setVoiceOverEnabledFromUI(_ enabled: Bool) {
        isVoiceOverEnabled = enabled
        guard let renderer else { return }
        Task {
            do {
                try await renderer.setAccessibility(
                    ReaderAccessibilitySettings(
                        isVoiceOverEnabled: enabled,
                        forceScrollWhenVoiceOverEnabled: true
                    )
                )
                await refreshState()
            } catch {
                errorMessage = "Accessibility update failed: \(error.localizedDescription)"
            }
        }
    }

    func copyCurrentLocator() {
        let payload = "ch=\(locator.sectionIndex + 1), section=\(Int(locator.sectionProgression * 100))%, book=\(Int(locator.totalProgression * 100))%"
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = payload
        #endif
    }

    func addBookmark() {
        guard let renderer else { return }
        let note = bookmarkNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                _ = try await renderer.addBookmark(note: note.isEmpty ? nil : note)
                bookmarkNoteDraft = ""
                await refreshState()
            } catch {
                errorMessage = "Add bookmark failed: \(error.localizedDescription)"
            }
        }
    }

    func removeBookmark(_ id: UUID) {
        guard let renderer else { return }
        Task {
            do {
                try await renderer.removeBookmark(id: id)
                await refreshState()
            } catch {
                errorMessage = "Delete bookmark failed: \(error.localizedDescription)"
            }
        }
    }

    func openBookmark(_ bookmark: ReadingBookmark) {
        guard let renderer, let book else { return }

        Task {
            do {
                let targetIndex = bookmark.position.spineIndex
                if targetIndex != selectedChapterIndex {
                    let preferences = await renderer.preferences()
                    try await renderer.renderChapter(
                        at: targetIndex,
                        viewport: viewport,
                        theme: preferences.theme,
                        typography: preferences.typography
                    )
                }
                try await renderer.go(to: book.locator(for: bookmark.position))
                await refreshState()
            } catch {
                errorMessage = "Open bookmark failed: \(error.localizedDescription)"
            }
        }
    }

    func handleSwipe(_ value: DragGesture.Value) {
        guard effectiveReadingMode == .paginated else {
            return
        }

        let horizontal = value.translation.width
        let vertical = value.translation.height
        guard abs(horizontal) > 60, abs(horizontal) > abs(vertical) else {
            return
        }

        if horizontal < 0 {
            nextPage()
        } else {
            previousPage()
        }
    }

    private func refreshState() async {
        guard let renderer else {
            position = .start
            locator = .start
            bookmarks = []
            canGoBack = false
            canGoForward = false
            return
        }

        position = await renderer.currentPosition()
        locator = await renderer.currentLocator()
        bookmarks = await renderer.bookmarks()
        canGoBack = renderer.canGoBack()
        canGoForward = renderer.canGoForward()
        readingMode = (await renderer.preferences()).readingMode
        effectiveReadingMode = await renderer.readingMode()

        if let book {
            selectedChapterIndex = clampChapterIndex(position.spineIndex, book: book)
        }
    }

    private func clampChapterIndex(_ index: Int, book: Book) -> Int {
        guard !book.readingOrder.isEmpty else {
            return 0
        }
        return min(max(index, 0), book.readingOrder.count - 1)
    }

    private func loadPosterImage(for book: Book) async throws -> PlatformImage? {
        guard !book.assets.isEmpty else {
            return nil
        }

        let loader = ResourceLoader(book: book, options: openOptions)
        let imageAssets = book.assets
            .filter { $0.mediaType.lowercased().hasPrefix("image/") }
            .sorted { lhs, rhs in
                scoreAssetForPoster(lhs) > scoreAssetForPoster(rhs)
            }

        for asset in imageAssets {
            guard let data = try await loader.data(forAssetID: asset.id) else {
                continue
            }
            if let image = PlatformImage(data: data) {
                return image
            }
        }
        return nil
    }

    private func scoreAssetForPoster(_ asset: Asset) -> Int {
        let key = "\(asset.id.lowercased()) \(asset.href.lowercased())"
        var score = 0
        if key.contains("cover") { score += 100 }
        if key.contains("poster") { score += 80 }
        if asset.mediaType.lowercased() == "image/jpeg" { score += 10 }
        return score
    }

    private static func readerStateDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("BookKitExample/ReaderState", isDirectory: true)
    }

    private func startPositionPolling() {
        positionPollTask?.cancel()
        positionPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let renderer = self.renderer else {
                    return
                }

                let next = await renderer.currentPosition()
                if next != self.position {
                    self.position = next
                    if let book = self.book {
                        self.selectedChapterIndex = self.clampChapterIndex(next.spineIndex, book: book)
                    }
                }
                self.locator = await renderer.currentLocator()
                self.canGoBack = renderer.canGoBack()
                self.canGoForward = renderer.canGoForward()
                self.readingMode = (await renderer.preferences()).readingMode
                self.effectiveReadingMode = await renderer.readingMode()

                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    deinit {
        positionPollTask?.cancel()
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

private extension View {
    @ViewBuilder
    func exampleGlassSurface(cornerRadius: CGFloat, tintOpacity: Double) -> some View {
        if #available(iOS 26, macOS 26, tvOS 26, visionOS 2, *) {
            glassEffect(
                .regular
                    .tint(.white.opacity(tintOpacity))
                    .interactive(),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }

    @ViewBuilder
    func exampleControlButtonStyle() -> some View {
        if #available(iOS 26, macOS 26, tvOS 26, visionOS 2, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.borderedProminent)
        }
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
