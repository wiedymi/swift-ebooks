import Foundation

public enum ReflowLayoutEvent: Sendable, Equatable {
    case ready
    case paginationChanged(PageMap)
    case positionChanged(Position)
    case linkTapped(url: URL, kind: LinkKind)
    case decorationTapped(id: String, group: DecorationGroup)
    case selectionChanged(range: SelectionRange, text: String)
    case contentHeightChanged(Double)
    case custom(name: String, payload: BridgeValue)
}

@MainActor
public final class ReflowLayout {
    private let bridge: any ReflowBridge
    private let allowsNetwork: Bool
    private var eventTask: Task<Void, Never>?

    public var events: AsyncStream<ReflowLayoutEvent> {
        eventHub.stream()
    }
    private let eventHub = EventHub<ReflowLayoutEvent>()

    private var lastPageMap = PageMap()
    private var lastPosition: Position?
    private var lastLinkTap: (url: URL, kind: LinkKind)?
    private var lastDecorationTap: (id: String, group: DecorationGroup)?
    private var lastSelection: (range: SelectionRange, text: String)?
    private var lastContentHeight: Double?
    private var readingMode: ReadingMode = .scroll
    private var currentSpineIndex: Int = 0

    public init(bridge: any ReflowBridge, options: OpenOptions = OpenOptions()) {
        self.bridge = bridge
        allowsNetwork = options.allowsNetwork
        startEventLoop()
    }

    deinit {
        eventTask?.cancel()
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
        lastPosition = Position(spineIndex: currentSpineIndex, progression: 0)
        let sanitized = SanitizeContent.run(chapter.content, allowsNetwork: allowsNetwork)
        let renderedHTML: String
        if let page = chapter.page {
            let width = page.pixelWidth.map(String.init) ?? ""
            let height = page.pixelHeight.map(String.init) ?? ""
            renderedHTML = """
            <div id="bookkit-fixed-page" data-width="\(width)" data-height="\(height)">
            \(sanitized)
            </div>
            """
        } else {
            renderedHTML = sanitized
        }
        var resolvedCSS = ResolveStyles.run(baseCSS: baseCSS, theme: theme, typography: typography)
        if chapter.page != nil {
            resolvedCSS += """
            \nhtml, body { width: 100%; height: 100%; overflow: hidden; }
            body { margin: 0; padding: 0; }
            #bookkit-fixed-page { transform-origin: top left; overflow: hidden; }
            #bookkit-fixed-page > img,
            #bookkit-fixed-page > svg { max-width: 100%; max-height: 100%; }
            """
        }
        let css = SanitizeContent.css(
            resolvedCSS,
            allowsNetwork: allowsNetwork
        )

        try await bridge.setNetworkAccessAllowed(allowsNetwork)
        try await bridge.setPublicationLayout(chapter.page == nil ? .reflowable : .fixed)
        try await bridge.setContent(html: renderedHTML, css: css, viewport: viewport)
        try await bridge.setReadingMode(readingMode)
        try await bridge.setTheme(theme)
        try await bridge.setTypography(typography)
        try await bridge.measurePages()
    }

    public func goToAnchor(_ id: String) async throws {
        try await bridge.goToAnchor(id)
        var position = lastPosition ?? Position(spineIndex: currentSpineIndex, progression: 0)
        position.fragment = id
        lastPosition = position
    }

    public func goToProgression(_ value: Double) async throws {
        let progression = min(max(value, 0), 1)
        try await bridge.goToProgression(progression)
        var position = lastPosition ?? Position(spineIndex: currentSpineIndex, progression: 0)
        position.progression = progression
        lastPosition = position
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

    public func setAccessibility(_ settings: ReaderAccessibilitySettings) async throws {
        try await bridge.setAccessibility(settings)
    }

    public func callBridgeCommand(_ name: String, payload: BridgeValue) async throws -> BridgeValue {
        try await bridge.callPlugin(name, payload: payload)
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
            eventHub.yield(.ready)

        case let .paginationChanged(pageCount, chapterProgressMap):
            let progress = chapterProgressMap[currentSpineIndex]
                ?? chapterProgressMap[0]
                ?? chapterProgressMap.values.first
                ?? []
            lastPageMap = PageMap(
                pageCount: pageCount,
                chapterProgressMap: [currentSpineIndex: progress]
            )
            eventHub.yield(.paginationChanged(lastPageMap))

        case let .positionChanged(_, progression, cfi, anchor):
            lastPosition = Position(spineIndex: currentSpineIndex, progression: progression, cfi: cfi, fragment: anchor)
            if let lastPosition {
                eventHub.yield(.positionChanged(lastPosition))
            }

        case let .linkTapped(url, kind):
            lastLinkTap = (url, kind)
            eventHub.yield(.linkTapped(url: url, kind: kind))

        case let .decorationTapped(id, group):
            lastDecorationTap = (id, group)
            eventHub.yield(.decorationTapped(id: id, group: group))

        case let .selectionChanged(range, text):
            lastSelection = (range, text)
            eventHub.yield(.selectionChanged(range: range, text: text))

        case let .contentHeightChanged(value):
            lastContentHeight = value
            eventHub.yield(.contentHeightChanged(value))

        case let .custom(name, payload):
            eventHub.yield(.custom(name: name, payload: payload))
        }
    }
}
