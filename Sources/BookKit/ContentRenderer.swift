import Foundation

@MainActor
final class ContentRenderer: Navigator {
    private struct RenderContext {
        let viewport: Viewport
        let theme: Theme
        let typography: Typography
        let baseCSS: String
    }

    let book: Book
    let mode: RenderMode
    var events: AsyncStream<NavigatorEvent> {
        eventHub.stream()
    }

    private let eventHub = EventHub<NavigatorEvent>()
    private let reader: ReaderStateActor
    private let reflowLayout: ReflowLayout?
    private let pdfAdapter: PDFPageAdapter?
    private let fixedPageAdapter: FixedPageAdapter?
    private let linkPolicy: any LinkPolicy
    private let maxHistoryDepth = 128

    private var lastRenderContext: RenderContext?
    private var layoutEventTask: Task<Void, Never>?
    private var currentChapterIndex: Int = 0
    private var backHistory: [Position] = []
    private var forwardHistory: [Position] = []
    private var decorationsByGroup: [DecorationGroup: [Decoration]] = [:]
    private var lastDecorationTapEvent: DecorationTapEvent?
    private var accessibilitySettings: ReaderAccessibilitySettings = .default

    convenience init(
        book: Book,
        options: OpenOptions = OpenOptions(),
        stateStore: (any ReaderStateStore)? = nil,
        linkPolicy: any LinkPolicy = DefaultLinkPolicy(),
        reflowBridge: (any ReflowBridge)? = nil,
        preferences: ReaderPreferences = .default
    ) throws {
        let normalizedBook = Normalize.run(book, allowsNetwork: options.allowsNetwork)
        try self.init(
            book: normalizedBook,
            reader: ReaderStateActor(
                book: normalizedBook,
                stateStore: stateStore,
                preferences: preferences
            ),
            options: options,
            linkPolicy: linkPolicy,
            reflowBridge: reflowBridge
        )
    }

    init(
        book: Book,
        reader: ReaderStateActor,
        options: OpenOptions,
        linkPolicy: any LinkPolicy,
        reflowBridge: (any ReflowBridge)?
    ) throws {
        self.book = book
        self.reader = reader
        self.linkPolicy = linkPolicy

        switch BookPresentationEngine(book: self.book) {
        case .audio:
            mode = .audio
            pdfAdapter = nil
            fixedPageAdapter = nil
            reflowLayout = nil

        case .pdf:
            mode = .pdf
            pdfAdapter = PDFPageAdapter(book: self.book)
            fixedPageAdapter = nil
            reflowLayout = nil

        case .bitmapFixed:
            mode = .fixed
            pdfAdapter = nil
            fixedPageAdapter = FixedPageAdapter(book: self.book)
            reflowLayout = nil

        case .reflow, .xhtmlFixed:
            mode = self.book.presentation.layout == .fixed ? .fixed : .reflow
            pdfAdapter = nil
            fixedPageAdapter = nil
            guard let reflowBridge else {
                throw BookError.renderingFailed("Reflow rendering requires a bridge implementation")
            }
            let layout = ReflowLayout(bridge: reflowBridge, options: options)
            reflowLayout = layout
            startLayoutEventLoop(layout: layout)
        }
    }

    deinit {
        layoutEventTask?.cancel()
    }

    func renderChapter(
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
        eventHub.yield(.preferencesChanged(nextPreferences))

        try await renderChapterInternal(
            at: index,
            viewport: viewport,
            baseCSS: baseCSS,
            preferences: nextPreferences
        )
    }

    func nextPage() async throws {
        let before = await currentPosition()
        let target = nextPageTarget(from: before)
        guard target != before else { return }
        try await navigateWithoutHistory(to: target)
        let after = await currentPosition()
        if after != before {
            eventHub.yield(.locatorChanged(book.locator(for: after)))
        }
    }

    func previousPage() async throws {
        let before = await currentPosition()
        let target = previousPageTarget(from: before)
        guard target != before else { return }
        try await navigateWithoutHistory(to: target)
        let after = await currentPosition()
        if after != before {
            eventHub.yield(.locatorChanged(book.locator(for: after)))
        }
    }

    func go(to position: Position) async throws {
        try await navigateWithoutHistory(to: position)
        let locator = await currentLocator()
        eventHub.yield(.locatorChanged(locator))
    }

    func go(to locator: Locator) async throws {
        let before = await currentPosition()
        try await navigateWithoutHistory(to: locator.position)
        let after = await currentPosition()
        recordHistoryTransition(from: before, to: after)
        eventHub.yield(.locatorChanged(book.locator(for: after)))
    }

    func go(to navigationItem: TOCNode) async throws {
        guard let locator = book.locator(forNavigationHref: navigationItem.href) else {
            throw BookError.navigationFailed(
                "Unable to resolve navigation destination: \(navigationItem.href)"
            )
        }
        try await go(to: locator)
    }

    func goBack() async throws -> Locator? {
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
        eventHub.yield(.locatorChanged(locator))
        return locator
    }

    func goForward() async throws -> Locator? {
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
        eventHub.yield(.locatorChanged(locator))
        return locator
    }

    func canGoBack() -> Bool {
        !backHistory.isEmpty
    }

    func canGoForward() -> Bool {
        !forwardHistory.isEmpty
    }

    func currentPosition() async -> Position {
        if let layoutPosition = reflowLayout?.position() {
            await reader.sync(to: layoutPosition)
            currentChapterIndex = layoutPosition.spineIndex
        }
        return await reader.position
    }

    func currentLocator() async -> Locator {
        let position = await currentPosition()
        return book.locator(for: position)
    }

    func pageCount() -> Int {
        switch mode {
        case .pdf:
            return pdfAdapter?.pageCount ?? 1
        case .fixed:
            return fixedPageAdapter?.pageCount ?? reflowLayout?.pageMap().pageCount ?? 1
        case .reflow:
            return reflowLayout?.pageMap().pageCount ?? 1
        case .audio:
            return max(book.readingOrder.count, 1)
        }
    }

    func pageMap() -> PageMap? {
        if let fixedPageAdapter {
            return PageMap(
                pageCount: fixedPageAdapter.pageCount,
                chapterProgressMap: Dictionary(
                    uniqueKeysWithValues: book.readingOrder.indices.map { ($0, [0]) }
                )
            )
        }
        return reflowLayout?.pageMap()
    }

    func restoreState() async throws {
        try await reader.restore()
        let restoredPosition = await reader.position
        let restoredPreferences = await reader.currentPreferences()

        eventHub.yield(.preferencesChanged(restoredPreferences))
        eventHub.yield(.readingModeChanged(effectiveReadingMode(preferences: restoredPreferences)))

        switch mode {
        case .pdf:
            currentChapterIndex = restoredPosition.spineIndex
            eventHub.yield(.locatorChanged(book.locator(for: restoredPosition)))

        case .fixed where fixedPageAdapter != nil:
            currentChapterIndex = fixedPageAdapter?.pageIndex(for: restoredPosition) ?? 0
            eventHub.yield(.locatorChanged(book.locator(for: restoredPosition)))

        case .audio:
            currentChapterIndex = min(
                max(restoredPosition.spineIndex, 0),
                max(book.readingOrder.count - 1, 0)
            )
            eventHub.yield(.locatorChanged(book.locator(for: restoredPosition)))

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
            eventHub.yield(.locatorChanged(book.locator(for: restoredPosition)))
        }
    }

    func addBookmark(note: String? = nil) async throws -> ReadingBookmark {
        if let layoutPosition = reflowLayout?.position() {
            try await reader.go(to: layoutPosition)
        }
        return try await reader.addBookmark(note: note)
    }

    func removeBookmark(id: UUID) async throws {
        try await reader.removeBookmark(id: id)
    }

    func updateBookmark(id: UUID, note: String?) async throws {
        try await reader.updateBookmark(id: id, note: note)
    }

    func bookmarks() async -> [ReadingBookmark] {
        await reader.bookmarksList()
    }

    func preferences() async -> ReaderPreferences {
        await reader.currentPreferences()
    }

    func setPreferences(_ preferences: ReaderPreferences) async throws {
        try await reader.setPreferences(preferences)
        eventHub.yield(.preferencesChanged(preferences))

        guard let layout = reflowLayout else {
            eventHub.yield(.readingModeChanged(effectiveReadingMode(preferences: preferences)))
            return
        }

        try await layout.setTheme(preferences.theme)
        try await layout.setTypography(preferences.typography)
        try await layout.setReadingMode(effectiveReadingMode(preferences: preferences))
        try await layout.measurePages()

        eventHub.yield(.readingModeChanged(effectiveReadingMode(preferences: preferences)))
    }

    func readingMode() async -> ReadingMode {
        let prefs = await reader.currentPreferences()
        return effectiveReadingMode(preferences: prefs)
    }

    func setReadingMode(_ mode: ReadingMode) async throws {
        var prefs = await reader.currentPreferences()
        prefs.readingMode = mode
        try await setPreferences(prefs)
    }

    func setTheme(_ theme: Theme) async throws {
        var prefs = await reader.currentPreferences()
        prefs.theme = theme
        try await setPreferences(prefs)
    }

    func setTypography(_ typography: Typography) async throws {
        var prefs = await reader.currentPreferences()
        prefs.typography = typography
        try await setPreferences(prefs)
    }

    func accessibility() -> ReaderAccessibilitySettings {
        accessibilitySettings
    }

    func setAccessibility(_ settings: ReaderAccessibilitySettings) async throws {
        accessibilitySettings = settings
        eventHub.yield(.accessibilityChanged(settings))

        let prefs = await reader.currentPreferences()
        guard let layout = reflowLayout else {
            eventHub.yield(.readingModeChanged(effectiveReadingMode(preferences: prefs)))
            return
        }

        try await layout.setAccessibility(settings)
        try await layout.setReadingMode(effectiveReadingMode(preferences: prefs))
        try await layout.measurePages()
        eventHub.yield(.readingModeChanged(effectiveReadingMode(preferences: prefs)))
    }

    func callBridgeCommand(
        _ name: String,
        payload: BridgeValue = .null
    ) async throws -> BridgeValue {
        guard let reflowLayout else {
            throw BookError.renderingFailed("Custom bridge commands are unavailable for this rendering mode")
        }
        return try await reflowLayout.callBridgeCommand(name, payload: payload)
    }

    func setDecorations(_ decorations: [Decoration], in group: DecorationGroup) async throws {
        decorationsByGroup[group] = decorations.map { decoration in
            var normalized = decoration
            if normalized.style == DecorationStyle() {
                normalized.style = .default(for: group)
            }
            return normalized
        }
        try await applyDecorationsForCurrentChapter()
    }

    func clearDecorations(in group: DecorationGroup? = nil) async throws {
        if let group {
            decorationsByGroup[group] = []
        } else {
            decorationsByGroup.removeAll()
        }
        try await applyDecorationsForCurrentChapter()
    }

    func decorations(in group: DecorationGroup) -> [Decoration] {
        decorationsByGroup[group] ?? []
    }

    func lastDecorationTap() -> DecorationTapEvent? {
        lastDecorationTapEvent
    }

    @discardableResult
    func handleLink(_ url: URL, context: LinkContext) async throws -> LinkAction {
        let action = await linkPolicy.action(for: url, context: context)
        let kind = ResolveLinks.classify(url)
        eventHub.yield(.linkActivated(url: url, kind: kind, action: action))

        guard action == .follow else {
            return action
        }

        let before = await currentPosition()

        switch kind {
        case .anchor:
            if let anchor = url.fragment {
                try await reflowLayout?.goToAnchor(anchor)
                var position = await reader.position
                position.fragment = anchor
                try await reader.go(to: position)
            }

        case .spine:
            if let index = resolveSpineIndex(for: url, context: context) {
                try await navigateWithoutHistory(to: Position(spineIndex: index, progression: 0))
            }
            if let anchor = url.fragment {
                try await reflowLayout?.goToAnchor(anchor)
                var position = await reader.position
                position.fragment = anchor
                try await reader.go(to: position)
            }

        case .external, .unsupported:
            break
        }

        let after = await currentPosition()
        recordHistoryTransition(from: before, to: after)
        eventHub.yield(.locatorChanged(book.locator(for: after)))

        return action
    }

    /// Applies the configured link policy and navigation behavior to a link from
    /// a CBZ, fixed-layout EPUB, image-only EPUB, or DjVu page.
    @discardableResult
    func handlePageLink(
        _ link: PageLink,
        onPageAt pageIndex: Int
    ) async throws -> LinkAction {
        guard book.readingOrder.indices.contains(pageIndex) else {
            throw BookError.navigationFailed("Fixed-page link source is outside the reading order")
        }
        guard let baseURL = URL(string: "bookkit://publication/"),
              let url = URL(string: link.href, relativeTo: baseURL)?.absoluteURL
        else {
            throw BookError.navigationFailed("Invalid fixed-page link: \(link.href)")
        }
        return try await handleLink(
            url,
            context: LinkContext(currentChapterHref: book.readingOrder[pageIndex].href)
        )
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
                eventHub.yield(.locatorChanged(book.locator(for: position)))
            }

        case .fixed where fixedPageAdapter != nil:
            guard let adapter = fixedPageAdapter else {
                throw BookError.renderingFailed("Missing fixed-page adapter")
            }
            let position = adapter.position(forPageIndex: index)
            currentChapterIndex = position.spineIndex
            try await reader.go(to: position)
            eventHub.yield(.locatorChanged(book.locator(for: position)))

        case .audio:
            guard !book.readingOrder.isEmpty else {
                throw BookError.malformedDocument("Audiobook has no tracks")
            }
            let trackIndex = min(max(index, 0), book.readingOrder.count - 1)
            let position = Position(spineIndex: trackIndex, progression: 0, timestamp: 0)
            currentChapterIndex = trackIndex
            try await reader.go(to: position)
            eventHub.yield(.locatorChanged(book.locator(for: position)))

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
            try await layout.setAccessibility(accessibilitySettings)
            try await layout.setReadingMode(effectiveMode)
            try await applyDecorationsForCurrentChapter()

            if let layoutPosition = layout.position() {
                try await reader.go(to: layoutPosition)
            }

            eventHub.yield(.readingModeChanged(effectiveMode))
            eventHub.yield(.locatorChanged(book.locator(for: await reader.position)))
        }
    }

    private func navigateWithoutHistory(to position: Position) async throws {
        switch mode {
        case .pdf:
            try await reader.go(to: position)
            currentChapterIndex = (await reader.position).spineIndex

        case .fixed where fixedPageAdapter != nil:
            guard let adapter = fixedPageAdapter else {
                throw BookError.renderingFailed("Missing fixed-page adapter")
            }
            let clamped = adapter.position(forPageIndex: position.spineIndex)
            try await reader.go(to: Position(
                spineIndex: clamped.spineIndex,
                progression: 0,
                cfi: position.cfi,
                fragment: position.fragment,
                textContext: position.textContext,
                timestamp: position.timestamp
            ))
            currentChapterIndex = clamped.spineIndex

        case .audio:
            guard !book.readingOrder.isEmpty else { return }
            let trackIndex = min(max(position.spineIndex, 0), book.readingOrder.count - 1)
            try await reader.go(to: Position(
                spineIndex: trackIndex,
                progression: position.progression,
                cfi: position.cfi,
                fragment: position.fragment,
                textContext: position.textContext,
                timestamp: position.timestamp
            ))
            currentChapterIndex = trackIndex

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
                textContext: position.textContext,
                timestamp: position.timestamp
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

    private func nextPageTarget(from position: Position) -> Position {
        if mode == .pdf || mode == .audio || fixedPageAdapter != nil {
            guard position.spineIndex + 1 < book.readingOrder.count else {
                return position
            }
            return Position(spineIndex: position.spineIndex + 1, progression: 0)
        }

        let pageProgressions = reflowLayout?.pageMap().chapterProgressMap[position.spineIndex] ?? []
        if let progression = pageProgressions
            .sorted()
            .first(where: { $0 > position.progression + 0.0001 })
        {
            return Position(spineIndex: position.spineIndex, progression: progression)
        }
        if position.spineIndex + 1 < book.readingOrder.count {
            return Position(spineIndex: position.spineIndex + 1, progression: 0)
        }
        if position.progression < 1 {
            return Position(spineIndex: position.spineIndex, progression: 1)
        }
        return position
    }

    private func previousPageTarget(from position: Position) -> Position {
        if mode == .pdf || mode == .audio || fixedPageAdapter != nil {
            guard position.spineIndex > 0 else {
                return position
            }
            return Position(spineIndex: position.spineIndex - 1, progression: 0)
        }

        let pageProgressions = reflowLayout?.pageMap().chapterProgressMap[position.spineIndex] ?? []
        if let progression = pageProgressions
            .sorted()
            .last(where: { $0 < position.progression - 0.0001 })
        {
            return Position(spineIndex: position.spineIndex, progression: progression)
        }
        if position.spineIndex > 0 {
            return Position(spineIndex: position.spineIndex - 1, progression: 1)
        }
        if position.progression > 0 {
            return Position(spineIndex: 0, progression: 0)
        }
        return position
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
        eventHub.yield(
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
        case .ready:
            eventHub.yield(.ready)

        case let .paginationChanged(pageMap):
            eventHub.yield(.paginationChanged(pageMap))

        case let .positionChanged(position):
            await reader.sync(to: position)
            currentChapterIndex = position.spineIndex
            eventHub.yield(.locatorChanged(book.locator(for: position)))

        case let .decorationTapped(id, group):
            let matched = decorationsByGroup[group]?.first(where: { $0.id == id })
            let event = DecorationTapEvent(id: id, group: group, locator: matched?.locator)
            lastDecorationTapEvent = event
            eventHub.yield(.decorationTapped(event))

        case let .linkTapped(url, _):
            let href = book.readingOrder.indices.contains(currentChapterIndex)
                ? book.readingOrder[currentChapterIndex].href
                : ""
            do {
                _ = try await handleLink(url, context: LinkContext(currentChapterHref: href))
            } catch {
                eventHub.yield(.error(BookError.from(error)))
            }

        case let .custom(name, payload):
            eventHub.yield(.bridgeMessage(name: name, payload: payload))

        case let .selectionChanged(range, text):
            let locator = await currentLocator()
            eventHub.yield(
                .selectionChanged(ReaderSelection(range: range, text: text, locator: locator))
            )

        case let .contentHeightChanged(value):
            eventHub.yield(.contentHeightChanged(value))
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
        guard !book.assets.isEmpty else {
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
            guard let asset = book.assets.last(where: { $0.id == decodedID && $0.data?.isEmpty == false }),
                  let data = asset.data else {
                continue
            }

            let mediaType = asset.mediaType.isEmpty ? "application/octet-stream" : asset.mediaType
            let dataURL = "data:\(mediaType);base64,\(data.base64EncodedString())"
            let quote = quotedWithDouble ? "\"" : "'"
            output.replaceSubrange(fullRange, with: "\(attribute)=\(quote)\(dataURL)\(quote)")
        }

        return output
    }
}
