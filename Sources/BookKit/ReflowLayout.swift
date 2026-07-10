import Foundation

public enum ReflowLayoutEvent: Sendable, Equatable {
    case ready
    case paginationChanged(PageMap)
    case positionChanged(Position)
    case linkTapped(url: URL, kind: LinkKind)
    case decorationTapped(id: String, group: DecorationGroup)
    case selectionChanged(range: SelectionRange, text: String)
    case contentHeightChanged(Double)
}

@MainActor
public final class ReflowLayout {
    private let bridge: any ReflowBridge
    private var eventTask: Task<Void, Never>?

    public let events: AsyncStream<ReflowLayoutEvent>
    private let continuation: AsyncStream<ReflowLayoutEvent>.Continuation

    private var lastPageMap = PageMap()
    private var lastPosition: Position?
    private var lastLinkTap: (url: URL, kind: LinkKind)?
    private var lastDecorationTap: (id: String, group: DecorationGroup)?
    private var lastSelection: (range: SelectionRange, text: String)?
    private var lastContentHeight: Double?
    private var readingMode: ReadingMode = .scroll
    private var currentSpineIndex: Int = 0

    public init(bridge: any ReflowBridge) {
        var streamContinuation: AsyncStream<ReflowLayoutEvent>.Continuation!
        events = AsyncStream<ReflowLayoutEvent> { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation

        self.bridge = bridge
        startEventLoop()
    }

    deinit {
        eventTask?.cancel()
        continuation.finish()
    }

    public func render(
        chapter: Chapter,
        spineIndex: Int = 0,
        baseCSS: String = "",
        viewport: Viewport,
        theme: Theme = .light,
        typography: Typography = .default
    ) async throws {
        currentSpineIndex = max(spineIndex, 0)
        let sanitized = SanitizeContent.run(chapter.content)
        let css = ResolveStyles.run(baseCSS: baseCSS, theme: theme, typography: typography)

        try await bridge.setContent(html: sanitized, css: css, viewport: viewport)
        try await bridge.setReadingMode(readingMode)
        try await bridge.setTheme(theme)
        try await bridge.setTypography(typography)
        try await bridge.measurePages()
    }

    public func goToAnchor(_ id: String) async throws {
        try await bridge.goToAnchor(id)
    }

    public func goToProgression(_ value: Double) async throws {
        try await bridge.goToProgression(value)
    }

    public func setReadingMode(_ mode: ReadingMode) async throws {
        readingMode = mode
        try await bridge.setReadingMode(mode)
    }

    public func setTheme(_ theme: Theme) async throws {
        try await bridge.setTheme(theme)
    }

    public func setTypography(_ typography: Typography) async throws {
        try await bridge.setTypography(typography)
    }

    public func setDecorations(_ decorations: [Decoration]) async throws {
        try await bridge.setDecorations(decorations)
    }

    public func measurePages() async throws {
        try await bridge.measurePages()
    }

    public func pageMap() -> PageMap {
        lastPageMap
    }

    public func position() -> Position? {
        lastPosition
    }

    public func latestLinkTap() -> (url: URL, kind: LinkKind)? {
        lastLinkTap
    }

    public func latestDecorationTap() -> (id: String, group: DecorationGroup)? {
        lastDecorationTap
    }

    public func latestSelection() -> (range: SelectionRange, text: String)? {
        lastSelection
    }

    public func contentHeight() -> Double? {
        lastContentHeight
    }

    private func startEventLoop() {
        let events = bridge.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    private func apply(_ event: ReflowBridgeEvent) {
        switch event {
        case .ready:
            continuation.yield(.ready)

        case let .paginationChanged(pageCount, chapterProgressMap):
            lastPageMap = PageMap(pageCount: pageCount, chapterProgressMap: chapterProgressMap)
            continuation.yield(.paginationChanged(lastPageMap))

        case let .positionChanged(_, progression, cfi, anchor):
            lastPosition = Position(spineIndex: currentSpineIndex, progression: progression, cfi: cfi, fragment: anchor)
            if let lastPosition {
                continuation.yield(.positionChanged(lastPosition))
            }

        case let .linkTapped(url, kind):
            lastLinkTap = (url, kind)
            continuation.yield(.linkTapped(url: url, kind: kind))

        case let .decorationTapped(id, group):
            lastDecorationTap = (id, group)
            continuation.yield(.decorationTapped(id: id, group: group))

        case let .selectionChanged(range, text):
            lastSelection = (range, text)
            continuation.yield(.selectionChanged(range: range, text: text))

        case let .contentHeightChanged(value):
            lastContentHeight = value
            continuation.yield(.contentHeightChanged(value))
        }
    }
}
