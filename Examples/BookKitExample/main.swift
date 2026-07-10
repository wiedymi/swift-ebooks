#if canImport(SwiftUI) && canImport(UniformTypeIdentifiers) && canImport(WebKit)
import BookKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

#if canImport(PDFKit) && !os(tvOS)
import PDFKit
#endif

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
        .task {
            model.syncSystemAccessibility()
            model.openDemoFromArgumentsIfPresent()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ExampleSystemAccessibility.primaryNotification)
        ) { _ in
            model.syncSystemAccessibility()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ExampleSystemAccessibility.secondaryNotification)
        ) { _ in
            model.syncSystemAccessibility()
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

            Button {
                model.pingExamplePlugin()
            } label: {
                Label("Plug-in", systemImage: "puzzlepiece.extension")
            }
            .exampleControlButtonStyle()
            .disabled(!model.canUsePlugin)
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
                    Text("Measured Pages: \(model.pageCount)")
                    Text("Content Height: \(Int(model.contentHeight)) pt")
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
                    Picker(
                        "Chapter",
                        selection: Binding(
                            get: { model.selectedChapterIndex },
                            set: { model.selectChapter($0) }
                        )
                    ) {
                        ForEach(Array(book.readingOrder.indices), id: \.self) { index in
                            let title = book.readingOrder[index].title?.ifEmpty("Untitled \(index + 1)") ?? "Untitled \(index + 1)"
                            Text("\(index + 1). \(title)").tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                }

                navigationPanel(title: "Table of Contents", nodes: book.tableOfContents)
                navigationPanel(title: "Landmarks", nodes: book.landmarks)
                navigationPanel(title: "Page List", nodes: book.pageList)

                DisclosureGroup("Live Reader Events") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let selection = model.latestSelection {
                            Text("Selection: \(selection.text)")
                                .lineLimit(3)
                        }
                        Text("Plug-in: \(model.pluginStatus)")
                        ForEach(Array(model.eventLog.suffix(8).enumerated()), id: \.offset) { _, event in
                            Text(event)
                        }
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    private func navigationPanel(title: String, nodes: [TOCNode]) -> some View {
        if !nodes.isEmpty {
            DisclosureGroup("\(title) (\(nodes.flatMap(\.flattened).count))") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(nodes) { node in
                        TOCBranch(node: node, depth: 0) { selected in
                            model.openNavigationItem(selected)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func readerPanel(book: Book) -> some View {
        if book.format == .pdf {
            if let data = book.assets.first(where: { $0.id == "pdf-document" })?.data {
                #if canImport(PDFKit) && !os(tvOS)
                PDFBookView(data: data, pageIndex: model.selectedChapterIndex)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #else
                Text(model.currentPDFPageText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            } else {
                Text(model.currentPDFPageText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let bridge = model.bridge {
            GeometryReader { geometry in
                BookView(bridge: bridge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task(id: geometry.size) {
                        model.updateViewport(size: geometry.size)
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

private struct TOCBranch: View {
    let node: TOCNode
    let depth: Int
    let action: (TOCNode) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if node.children.isEmpty {
                    Color.clear.frame(width: 14, height: 1)
                } else {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
                }

                Button(node.title.ifEmpty("Untitled")) {
                    action(node)
                }
                .buttonStyle(.plain)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 12)

            if isExpanded {
                ForEach(node.children) { child in
                    TOCBranch(node: child, depth: depth + 1, action: action)
                }
            }
        }
        .font(.caption)
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
    @Published var isReducedMotionEnabled = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var pageCount = 1
    @Published var contentHeight: Double = 0
    @Published var latestSelection: ReaderSelection?
    @Published var pluginStatus = "Idle"
    @Published var eventLog: [String] = []

    @Published private var viewport = Viewport(width: 740, height: 900)

    var canNavigate: Bool { renderer != nil }
    var canUsePlugin: Bool { bridge != nil && renderer != nil }

    private var eventTask: Task<Void, Never>?
    private var viewportTask: Task<Void, Never>?
    private var didAttemptDemoOpen = false
    private var isAutomatedDemoLaunch = false

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

        eventTask?.cancel()
        viewportTask?.cancel()

        do {
            let loadedBook = try await Book.open(from: url, options: openOptions)
            let bridge = loadedBook.format == .pdf ? nil : WebViewReflowBridge(
                configuration: WebViewReflowConfiguration(
                    plugins: [Self.examplePlugin]
                )
            )
            let renderer = try ContentRenderer(
                book: loadedBook,
                options: openOptions,
                stateStore: stateStore,
                reflowBridge: bridge
            )

            self.book = loadedBook
            self.bridge = bridge
            self.renderer = renderer
            startEventSubscription(renderer: renderer)
            self.posterImage = await loadPosterImage(for: loadedBook)

            try await renderer.restoreState()
            let restoredPreferences = await renderer.preferences()
            readingMode = restoredPreferences.readingMode
            let restoredPosition = await renderer.currentPosition()
            selectedChapterIndex = clampChapterIndex(restoredPosition.spineIndex, book: loadedBook)

            try await renderer.setAccessibility(
                ReaderAccessibilitySettings(
                    isVoiceOverEnabled: isVoiceOverEnabled,
                    forceScrollWhenVoiceOverEnabled: true,
                    prefersReducedMotion: isReducedMotionEnabled,
                    announcesPositionChanges: isVoiceOverEnabled
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
            appendEvent("Opened \(loadedBook.format.rawValue.uppercased()) • \(loadedBook.readingOrder.count) sections")
            if isAutomatedDemoLaunch {
                print(
                    "BOOKKIT_EXAMPLE_READY format=\(loadedBook.format.rawValue) "
                        + "chapters=\(loadedBook.readingOrder.count) "
                        + "toc=\(loadedBook.tableOfContents.flatMap(\.flattened).count)"
                )
            }
        } catch {
            errorMessage = "Open failed: \(error.localizedDescription)"
            eventTask?.cancel()
            if isAutomatedDemoLaunch {
                print("BOOKKIT_EXAMPLE_FAILED \(error.localizedDescription)")
            }
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

        viewportTask?.cancel()
        viewportTask = Task { @MainActor [weak self, weak renderer] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let self, let renderer else { return }
            do {
                let restoredPosition = await renderer.currentPosition()
                let preferences = await renderer.preferences()
                try await renderer.renderChapter(
                    at: restoredPosition.spineIndex,
                    viewport: self.viewport,
                    theme: preferences.theme,
                    typography: preferences.typography
                )
                try await renderer.go(to: restoredPosition)
                await self.refreshState()
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = "Rerender failed: \(error.localizedDescription)"
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
        applyAccessibilitySettings()
    }

    func syncSystemAccessibility() {
        let voiceOver = ExampleSystemAccessibility.isVoiceOverEnabled
        let reducedMotion = ExampleSystemAccessibility.prefersReducedMotion
        guard voiceOver != isVoiceOverEnabled || reducedMotion != isReducedMotionEnabled else {
            return
        }
        isVoiceOverEnabled = voiceOver
        isReducedMotionEnabled = reducedMotion
        applyAccessibilitySettings()
    }

    func openDemoFromArgumentsIfPresent() {
        guard !didAttemptDemoOpen else { return }
        didAttemptDemoOpen = true

        let arguments = ProcessInfo.processInfo.arguments
        let argumentPath: String?
        if let flag = arguments.firstIndex(of: "--demo"), arguments.indices.contains(flag + 1) {
            argumentPath = arguments[flag + 1]
        } else {
            argumentPath = ProcessInfo.processInfo.environment["BOOKKIT_DEMO_PATH"]
        }
        guard let path = argumentPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        isAutomatedDemoLaunch = true
        let expanded = (path as NSString).expandingTildeInPath
        Task { @MainActor [weak self] in
            await self?.openBook(at: URL(fileURLWithPath: expanded))
        }
    }

    func openNavigationItem(_ item: TOCNode) {
        guard let renderer else { return }
        Task {
            do {
                try await renderer.go(to: item)
                await refreshState()
            } catch {
                errorMessage = "Navigation failed: \(error.localizedDescription)"
            }
        }
    }

    func pingExamplePlugin() {
        guard let renderer else { return }
        Task {
            do {
                let result = try await renderer.callBridgeCommand(
                    "example.ping",
                    payload: .object(["message": .string("Hello from Swift")])
                )
                pluginStatus = "Reply: \(Self.describe(result))"
                appendEvent("Custom command completed")
            } catch {
                pluginStatus = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func applyAccessibilitySettings() {
        guard let renderer else { return }
        let settings = ReaderAccessibilitySettings(
            isVoiceOverEnabled: isVoiceOverEnabled,
            forceScrollWhenVoiceOverEnabled: true,
            prefersReducedMotion: isReducedMotionEnabled,
            announcesPositionChanges: isVoiceOverEnabled
        )
        Task { @MainActor [weak self, weak renderer] in
            guard let self, let renderer else { return }
            do {
                try await renderer.setAccessibility(settings)
                await self.refreshState()
            } catch {
                self.errorMessage = "Accessibility update failed: \(error.localizedDescription)"
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
            pageCount = 1
            return
        }

        position = await renderer.currentPosition()
        locator = await renderer.currentLocator()
        bookmarks = await renderer.bookmarks()
        canGoBack = renderer.canGoBack()
        canGoForward = renderer.canGoForward()
        readingMode = (await renderer.preferences()).readingMode
        effectiveReadingMode = await renderer.readingMode()
        pageCount = renderer.pageCount()

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

    private func loadPosterImage(for book: Book) async -> PlatformImage? {
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
            do {
                guard let data = try await loader.data(forAssetID: asset.id) else {
                    continue
                }
                if let image = PlatformImage(data: data) {
                    return image
                }
            } catch {
                appendEvent("Skipped invalid poster candidate \(asset.id)")
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

    private func startEventSubscription(renderer: ContentRenderer) {
        eventTask?.cancel()
        let events = renderer.events
        eventTask = Task { @MainActor [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: NavigatorEvent) {
        switch event {
        case .ready:
            appendEvent("Renderer ready")
        case let .locatorChanged(value):
            locator = value
            position = value.position
            if let book {
                selectedChapterIndex = clampChapterIndex(value.sectionIndex, book: book)
            }
        case let .paginationChanged(value):
            pageCount = value.pageCount
        case let .selectionChanged(value):
            latestSelection = value
            appendEvent("Selected \(value.text.prefix(36))")
        case let .contentHeightChanged(value):
            contentHeight = value
        case let .historyChanged(back, forward):
            canGoBack = back
            canGoForward = forward
        case let .readingModeChanged(value):
            effectiveReadingMode = value
        case let .preferencesChanged(value):
            readingMode = value.readingMode
        case let .accessibilityChanged(value):
            isVoiceOverEnabled = value.isVoiceOverEnabled
            isReducedMotionEnabled = value.prefersReducedMotion
            appendEvent("Accessibility settings applied")
        case let .linkActivated(url, kind, action):
            appendEvent("Link \(kind.rawValue): \(action) • \(url.absoluteString)")
        case let .decorationTapped(value):
            appendEvent("Decoration tapped: \(value.group.rawValue)/\(value.id)")
        case let .bridgeMessage(name, payload):
            pluginStatus = "\(name): \(Self.describe(payload))"
            appendEvent("Plug-in event: \(name)")
        case let .error(error):
            errorMessage = error.localizedDescription
            appendEvent("Renderer error")
        }
    }

    private func appendEvent(_ value: String) {
        eventLog.append(value)
        if eventLog.count > 50 {
            eventLog.removeFirst(eventLog.count - 50)
        }
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

    deinit {
        eventTask?.cancel()
        viewportTask?.cancel()
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
        #if os(visionOS)
        background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        #else
        if #available(iOS 26, macOS 26, tvOS 26, *) {
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
        #endif
    }

    @ViewBuilder
    func exampleControlButtonStyle() -> some View {
        #if os(visionOS)
        buttonStyle(.borderedProminent)
        #else
        if #available(iOS 26, macOS 26, tvOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.borderedProminent)
        }
        #endif
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
