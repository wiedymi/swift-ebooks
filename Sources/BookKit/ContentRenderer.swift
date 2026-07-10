import Foundation

@MainActor
public final class ContentRenderer: Navigator {
    private struct RenderContext {
        let viewport: Viewport
        let theme: Theme
        let typography: Typography
        let baseCSS: String
    }

    public let book: Book
    public let mode: RenderMode
    public let events: AsyncStream<NavigatorEvent>

    private let eventsContinuation: AsyncStream<NavigatorEvent>.Continuation
    private let reader: Reader
    private let reflowLayout: ReflowLayout?
    private let pdfAdapter: PDFPageAdapter?
    private let linkPolicy: any LinkPolicy
    private let embeddedAssetDataURLByID: [String: String]
    private let maxHistoryDepth = 128

    private var lastRenderContext: RenderContext?
    private var layoutEventTask: Task<Void, Never>?
    private var currentChapterIndex: Int = 0
    private var backHistory: [Position] = []
    private var forwardHistory: [Position] = []
    private var decorationsByGroup: [DecorationGroup: [Decoration]] = [:]
    private var lastDecorationTapEvent: DecorationTapEvent?
    private var accessibilitySettings: ReaderAccessibilitySettings = .default

    public init(
        book: Book,
        options _: OpenOptions = OpenOptions(),
        stateStore: (any ReaderStateStore)? = nil,
        linkPolicy: any LinkPolicy = DefaultLinkPolicy(),
        reflowBridge: (any ReflowBridge)? = nil,
        preferences: ReaderPreferences = .default
    ) throws {
        var streamContinuation: AsyncStream<NavigatorEvent>.Continuation!
        events = AsyncStream<NavigatorEvent> { continuation in
            streamContinuation = continuation
        }
        eventsContinuation = streamContinuation

        self.book = Normalize.run(book)
        reader = Reader(book: self.book, stateStore: stateStore, preferences: preferences)
        self.linkPolicy = linkPolicy
        embeddedAssetDataURLByID = Self.makeEmbeddedAssetDataURLMap(assets: self.book.assets)

        if self.book.format == .pdf {
            mode = .pdf
            pdfAdapter = PDFPageAdapter(book: self.book)
            reflowLayout = nil
        } else {
            mode = .reflow
            pdfAdapter = nil
            guard let reflowBridge else {
                throw BookError.renderingFailed("Reflow rendering requires a bridge implementation")
            }
            let layout = ReflowLayout(bridge: reflowBridge)
            reflowLayout = layout
            startLayoutEventLoop(layout: layout)
        }
    }

    deinit {
        layoutEventTask?.cancel()
        eventsContinuation.finish()
    }

    public func renderChapter(
        at index: Int,
        viewport: Viewport,
        theme: Theme = .light,
        typography: Typography = .default,
        baseCSS: String = ""
    ) async throws {
        var nextPreferences = await reader.currentPreferences()
        nextPreferences.theme = theme
        nextPreferences.typography = typography
        try await reader.setPreferences(nextPreferences)
        eventsContinuation.yield(.preferencesChanged(nextPreferences))

        try await renderChapterInternal(
            at: index,
            viewport: viewport,
            baseCSS: baseCSS,
            preferences: nextPreferences
        )
    }

    public func nextPage() async throws {
        let before = await currentPosition()
        try await reader.nextPage()
        let target = await reader.position
        try await navigateWithoutHistory(to: target)
        let after = await currentPosition()
        if after != before {
            eventsContinuation.yield(.locatorChanged(book.locator(for: after)))
        }
    }

    public func previousPage() async throws {
        let before = await currentPosition()
        try await reader.previousPage()
        let target = await reader.position
        try await navigateWithoutHistory(to: target)
        let after = await currentPosition()
        if after != before {
            eventsContinuation.yield(.locatorChanged(book.locator(for: after)))
        }
    }

    public func go(to position: Position) async throws {
        try await navigateWithoutHistory(to: position)
        let locator = await currentLocator()
        eventsContinuation.yield(.locatorChanged(locator))
    }

    public func go(to locator: Locator) async throws {
        let before = await currentPosition()
        try await navigateWithoutHistory(to: locator.position)
        let after = await currentPosition()
        recordHistoryTransition(from: before, to: after)
        eventsContinuation.yield(.locatorChanged(book.locator(for: after)))
    }

    public func goBack() async throws -> Locator? {
        guard let target = backHistory.popLast() else {
            return nil
        }

        let current = await currentPosition()
        if current != target {
            forwardHistory.append(current)
            trimHistoryIfNeeded(&forwardHistory)
        }

        try await navigateWithoutHistory(to: target)
        emitHistoryChanged()

        let locator = await currentLocator()
        eventsContinuation.yield(.locatorChanged(locator))
        return locator
    }

    public func goForward() async throws -> Locator? {
        guard let target = forwardHistory.popLast() else {
            return nil
        }

        let current = await currentPosition()
        if current != target {
            backHistory.append(current)
            trimHistoryIfNeeded(&backHistory)
        }

        try await navigateWithoutHistory(to: target)
        emitHistoryChanged()

        let locator = await currentLocator()
        eventsContinuation.yield(.locatorChanged(locator))
        return locator
    }

    public func canGoBack() -> Bool {
        !backHistory.isEmpty
    }

    public func canGoForward() -> Bool {
        !forwardHistory.isEmpty
    }

    public func currentPosition() async -> Position {
        if let layoutPosition = reflowLayout?.position() {
            await reader.sync(to: layoutPosition)
            currentChapterIndex = layoutPosition.spineIndex
        }
        return await reader.position
    }

    public func currentLocator() async -> Locator {
        let position = await currentPosition()
        return book.locator(for: position)
    }

    public func pageCount() -> Int {
        switch mode {
        case .pdf:
            return pdfAdapter?.pageCount ?? 1
        case .reflow, .fixed:
            return reflowLayout?.pageMap().pageCount ?? 1
        }
    }

    public func pageMap() -> PageMap? {
        reflowLayout?.pageMap()
    }

    public func restoreState() async throws {
        try await reader.restore()
        let restoredPosition = await reader.position
        let restoredPreferences = await reader.currentPreferences()

        eventsContinuation.yield(.preferencesChanged(restoredPreferences))
        eventsContinuation.yield(.readingModeChanged(effectiveReadingMode(preferences: restoredPreferences)))

        switch mode {
        case .pdf:
            currentChapterIndex = restoredPosition.spineIndex
            eventsContinuation.yield(.locatorChanged(book.locator(for: restoredPosition)))

        case .reflow, .fixed:
            if let context = lastRenderContext {
                try await renderChapterInternal(
                    at: restoredPosition.spineIndex,
                    viewport: context.viewport,
                    baseCSS: context.baseCSS,
                    preferences: restoredPreferences
                )
                try await reflowLayout?.goToProgression(restoredPosition.progression)
                if let anchor = restoredPosition.fragment {
                    try await reflowLayout?.goToAnchor(anchor)
                }
            } else {
                currentChapterIndex = restoredPosition.spineIndex
                try await reader.go(to: restoredPosition)
            }
            eventsContinuation.yield(.locatorChanged(book.locator(for: restoredPosition)))
        }
    }

    public func addBookmark(note: String? = nil) async throws -> ReadingBookmark {
        if let layoutPosition = reflowLayout?.position() {
            try await reader.go(to: layoutPosition)
        }
        return try await reader.addBookmark(note: note)
    }

    public func removeBookmark(id: UUID) async throws {
        try await reader.removeBookmark(id: id)
    }

    public func updateBookmark(id: UUID, note: String?) async throws {
        try await reader.updateBookmark(id: id, note: note)
    }

    public func bookmarks() async -> [ReadingBookmark] {
        await reader.bookmarksList()
    }

    public func preferences() async -> ReaderPreferences {
        await reader.currentPreferences()
    }

    public func setPreferences(_ preferences: ReaderPreferences) async throws {
        try await reader.setPreferences(preferences)
        eventsContinuation.yield(.preferencesChanged(preferences))

        guard let layout = reflowLayout else {
            eventsContinuation.yield(.readingModeChanged(effectiveReadingMode(preferences: preferences)))
            return
        }

        try await layout.setTheme(preferences.theme)
        try await layout.setTypography(preferences.typography)
        try await layout.setReadingMode(effectiveReadingMode(preferences: preferences))
        try await layout.measurePages()

        eventsContinuation.yield(.readingModeChanged(effectiveReadingMode(preferences: preferences)))
    }

    public func readingMode() async -> ReadingMode {
        let prefs = await reader.currentPreferences()
        return effectiveReadingMode(preferences: prefs)
    }

    public func setReadingMode(_ mode: ReadingMode) async throws {
        var prefs = await reader.currentPreferences()
        prefs.readingMode = mode
        try await setPreferences(prefs)
    }

    public func setTheme(_ theme: Theme) async throws {
        var prefs = await reader.currentPreferences()
        prefs.theme = theme
        try await setPreferences(prefs)
    }

    public func setTypography(_ typography: Typography) async throws {
        var prefs = await reader.currentPreferences()
        prefs.typography = typography
        try await setPreferences(prefs)
    }

    public func accessibility() -> ReaderAccessibilitySettings {
        accessibilitySettings
    }

    public func setAccessibility(_ settings: ReaderAccessibilitySettings) async throws {
        accessibilitySettings = settings
        eventsContinuation.yield(.accessibilityChanged(settings))

        let prefs = await reader.currentPreferences()
        guard let layout = reflowLayout else {
            eventsContinuation.yield(.readingModeChanged(effectiveReadingMode(preferences: prefs)))
            return
        }

        try await layout.setReadingMode(effectiveReadingMode(preferences: prefs))
        try await layout.measurePages()
        eventsContinuation.yield(.readingModeChanged(effectiveReadingMode(preferences: prefs)))
    }

    public func setDecorations(_ decorations: [Decoration], in group: DecorationGroup) async throws {
        decorationsByGroup[group] = decorations.map { decoration in
            var normalized = decoration
            if normalized.style == DecorationStyle() {
                normalized.style = .default(for: group)
            }
            return normalized
        }
        try await applyDecorationsForCurrentChapter()
    }

    public func clearDecorations(in group: DecorationGroup? = nil) async throws {
        if let group {
            decorationsByGroup[group] = []
        } else {
            decorationsByGroup.removeAll()
        }
        try await applyDecorationsForCurrentChapter()
    }

    public func decorations(in group: DecorationGroup) -> [Decoration] {
        decorationsByGroup[group] ?? []
    }

    public func lastDecorationTap() -> DecorationTapEvent? {
        lastDecorationTapEvent
    }

    @discardableResult
    public func handleLink(_ url: URL, context: LinkContext) async throws -> LinkAction {
        let action = await linkPolicy.action(for: url, context: context)
        let kind = ResolveLinks.classify(url)
        eventsContinuation.yield(.linkActivated(url: url, kind: kind, action: action))

        guard action == .follow else {
            return action
        }

        let before = await currentPosition()

        switch kind {
        case .anchor:
            if let anchor = url.fragment {
                try await reflowLayout?.goToAnchor(anchor)
                if var position = reflowLayout?.position() {
                    position.fragment = anchor
                    try await reader.go(to: position)
                }
            }

        case .spine:
            if let index = resolveSpineIndex(for: url, context: context) {
                try await navigateWithoutHistory(to: Position(spineIndex: index, progression: 0))
            }
            if let anchor = url.fragment {
                try await reflowLayout?.goToAnchor(anchor)
                if var position = reflowLayout?.position() {
                    position.fragment = anchor
                    try await reader.go(to: position)
                }
            }

        case .external, .unsupported:
            break
        }

        let after = await currentPosition()
        recordHistoryTransition(from: before, to: after)
        eventsContinuation.yield(.locatorChanged(book.locator(for: after)))

        return action
    }

    private func renderChapterInternal(
        at index: Int,
        viewport: Viewport,
        baseCSS: String,
        preferences: ReaderPreferences
    ) async throws {
        lastRenderContext = RenderContext(
            viewport: viewport,
            theme: preferences.theme,
            typography: preferences.typography,
            baseCSS: baseCSS
        )

        switch mode {
        case .pdf:
            if let adapter = pdfAdapter {
                let position = adapter.position(forPageIndex: index)
                currentChapterIndex = position.spineIndex
                try await reader.go(to: position)
                eventsContinuation.yield(.locatorChanged(book.locator(for: position)))
            }

        case .reflow, .fixed:
            guard let layout = reflowLayout else {
                throw BookError.renderingFailed("Missing reflow layout")
            }

            guard !book.readingOrder.isEmpty else {
                throw BookError.malformedDocument("Book has no chapters")
            }

            let chapterIndex = min(max(index, 0), book.readingOrder.count - 1)
            currentChapterIndex = chapterIndex
            let chapter = chapterForRendering(at: chapterIndex)

            try await reader.go(to: Position(spineIndex: chapterIndex, progression: 0))
            try await layout.render(
                chapter: chapter,
                spineIndex: chapterIndex,
                baseCSS: baseCSS,
                viewport: viewport,
                theme: preferences.theme,
                typography: preferences.typography
            )

            let effectiveMode = effectiveReadingMode(preferences: preferences)
            try await layout.setReadingMode(effectiveMode)
            try await applyDecorationsForCurrentChapter()

            if let layoutPosition = layout.position() {
                try await reader.go(to: layoutPosition)
            }

            eventsContinuation.yield(.readingModeChanged(effectiveMode))
            eventsContinuation.yield(.locatorChanged(book.locator(for: await reader.position)))
        }
    }

    private func navigateWithoutHistory(to position: Position) async throws {
        switch mode {
        case .pdf:
            try await reader.go(to: position)
            currentChapterIndex = (await reader.position).spineIndex

        case .reflow, .fixed:
            guard let layout = reflowLayout else {
                throw BookError.renderingFailed("Missing reflow layout")
            }

            guard !book.readingOrder.isEmpty else {
                return
            }

            let targetIndex = min(max(position.spineIndex, 0), book.readingOrder.count - 1)
            if targetIndex != currentChapterIndex, let context = lastRenderContext {
                let prefs = await reader.currentPreferences()
                try await renderChapterInternal(
                    at: targetIndex,
                    viewport: context.viewport,
                    baseCSS: context.baseCSS,
                    preferences: prefs
                )
            } else if targetIndex != currentChapterIndex {
                currentChapterIndex = targetIndex
            }

            try await reader.go(to: Position(
                spineIndex: targetIndex,
                progression: position.progression,
                cfi: position.cfi,
                fragment: position.fragment,
                textContext: position.textContext
            ))
            try await layout.goToProgression(position.progression)

            if let anchor = position.fragment {
                try await layout.goToAnchor(anchor)
            }
            if let layoutPosition = layout.position() {
                await reader.sync(to: layoutPosition)
                currentChapterIndex = layoutPosition.spineIndex
            }
            try await applyDecorationsForCurrentChapter()
        }
    }

    private func applyDecorationsForCurrentChapter() async throws {
        guard let layout = reflowLayout else {
            return
        }

        let decorations = decorationsByGroup.values
            .flatMap { $0 }
            .filter { decoration in
                decoration.locator.sectionIndex == currentChapterIndex &&
                    !(decoration.locator.anchor?.isEmpty ?? true)
            }
        try await layout.setDecorations(decorations)
    }

    private func effectiveReadingMode(preferences: ReaderPreferences) -> ReadingMode {
        if accessibilitySettings.isVoiceOverEnabled, accessibilitySettings.forceScrollWhenVoiceOverEnabled {
            return .scroll
        }
        return preferences.readingMode
    }

    private func recordHistoryTransition(from before: Position, to after: Position) {
        guard before != after else {
            return
        }
        backHistory.append(before)
        trimHistoryIfNeeded(&backHistory)
        forwardHistory.removeAll()
        emitHistoryChanged()
    }

    private func trimHistoryIfNeeded(_ stack: inout [Position]) {
        let overflow = stack.count - maxHistoryDepth
        guard overflow > 0 else {
            return
        }
        stack.removeFirst(overflow)
    }

    private func emitHistoryChanged() {
        eventsContinuation.yield(
            .historyChanged(
                canGoBack: !backHistory.isEmpty,
                canGoForward: !forwardHistory.isEmpty
            )
        )
    }

    private func startLayoutEventLoop(layout: ReflowLayout) {
        let events = layout.events
        layoutEventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handleLayoutEvent(event)
            }
        }
    }

    private func handleLayoutEvent(_ event: ReflowLayoutEvent) async {
        switch event {
        case let .positionChanged(position):
            await reader.sync(to: position)
            currentChapterIndex = position.spineIndex
            eventsContinuation.yield(.locatorChanged(book.locator(for: position)))

        case let .decorationTapped(id, group):
            let matched = decorationsByGroup[group]?.first(where: { $0.id == id })
            let event = DecorationTapEvent(id: id, group: group, locator: matched?.locator)
            lastDecorationTapEvent = event
            eventsContinuation.yield(.decorationTapped(event))

        case .ready, .paginationChanged, .selectionChanged, .contentHeightChanged, .linkTapped:
            break
        }
    }

    private func resolveSpineIndex(for url: URL, context: LinkContext) -> Int? {
        guard !book.readingOrder.isEmpty else {
            return nil
        }

        let path = normalizedSpinePath(from: url.path)
        if path.isEmpty {
            return nil
        }

        let currentHref = normalizedSpinePath(from: context.currentChapterHref)
        let currentDir = normalizedSpinePath(from: (currentHref as NSString).deletingLastPathComponent)

        var candidates: [String] = []
        if path == "current", !currentHref.isEmpty {
            candidates.append(currentHref)
        } else {
            candidates.append(path)
            if !currentDir.isEmpty, !path.contains("/") {
                candidates.append(normalizedSpinePath(from: (currentDir as NSString).appendingPathComponent(path)))
            }
        }

        for candidate in candidates where !candidate.isEmpty {
            if let exact = book.readingOrder.firstIndex(where: { normalizedSpinePath(from: $0.href) == candidate }) {
                return exact
            }

            if let suffix = book.readingOrder.firstIndex(where: {
                let href = normalizedSpinePath(from: $0.href)
                return href.hasSuffix("/" + candidate) || candidate.hasSuffix("/" + href)
            }) {
                return suffix
            }
        }

        return nil
    }

    private func normalizedSpinePath(from raw: String) -> String {
        let noFragment = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        let noQuery = noFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? noFragment
        let decoded = (noQuery.removingPercentEncoding ?? noQuery).replacingOccurrences(of: "\\", with: "/")

        var parts: [String] = []
        for component in decoded.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                if !parts.isEmpty {
                    parts.removeLast()
                }
                continue
            }
            parts.append(String(component))
        }

        return parts.joined(separator: "/")
    }

    private func chapterForRendering(at index: Int) -> Chapter {
        var chapter = book.readingOrder[index]
        chapter.content = inlineAssetReferences(in: chapter.content)
        return chapter
    }

    private func inlineAssetReferences(in html: String) -> String {
        guard !embeddedAssetDataURLByID.isEmpty else {
            return html
        }

        let pattern = "(?i)(src|href)\\s*=\\s*(\"bookkit://asset/([^\"]+)\"|'bookkit://asset/([^']+)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return html
        }

        var output = html
        let matches = regex.matches(in: output, options: [], range: NSRange(output.startIndex..<output.endIndex, in: output))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: output),
                  let attrRange = Range(match.range(at: 1), in: output)
            else {
                continue
            }

            let attribute = String(output[attrRange])
            let quotedWithDouble = match.range(at: 3).location != NSNotFound
            let valueRange = quotedWithDouble ? Range(match.range(at: 3), in: output) : Range(match.range(at: 4), in: output)
            guard let valueRange else {
                continue
            }

            let rawID = String(output[valueRange])
            let decodedID = rawID.removingPercentEncoding ?? rawID
            guard let dataURL = embeddedAssetDataURLByID[decodedID] else {
                continue
            }

            let quote = quotedWithDouble ? "\"" : "'"
            output.replaceSubrange(fullRange, with: "\(attribute)=\(quote)\(dataURL)\(quote)")
        }

        return output
    }

    private static func makeEmbeddedAssetDataURLMap(assets: [Asset]) -> [String: String] {
        var output: [String: String] = [:]
        for asset in assets {
            guard let data = asset.data, !data.isEmpty else {
                continue
            }

            let mediaType = asset.mediaType.isEmpty ? "application/octet-stream" : asset.mediaType
            let dataURL = "data:\(mediaType);base64,\(data.base64EncodedString())"
            output[asset.id] = dataURL
        }
        return output
    }
}
