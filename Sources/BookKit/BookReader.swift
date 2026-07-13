import Combine
import Foundation

#if canImport(WebKit)
import WebKit
#endif

/// An opened publication and its complete reading session.
///
/// `BookReader` chooses and owns the appropriate rendering or playback engine,
/// restores persistent state, keeps view callbacks synchronized with navigation,
/// and exposes one observable state surface for every supported format.
@MainActor
public final class BookReader: ObservableObject {
    /// The normalized publication owned by this session.
    public let book: Book

    /// The current position in the publication.
    @Published public internal(set) var position: Position

    /// The current portable locator.
    @Published public internal(set) var locator: Locator

    /// The effective reading preferences.
    @Published public internal(set) var preferences: ReaderPreferences

    /// The effective accessibility settings.
    @Published public internal(set) var accessibility: ReaderAccessibilitySettings

    /// Persisted bookmarks for this publication.
    @Published public internal(set) var bookmarks: [ReadingBookmark]

    /// Whether the reader can navigate backward through its history.
    @Published public internal(set) var canGoBack: Bool

    /// Whether the reader can navigate forward through its history.
    @Published public internal(set) var canGoForward: Bool

    /// The currently measured or known page count.
    @Published public internal(set) var pageCount: Int

    /// The current pagination map, when one is available.
    @Published public internal(set) var pageMap: PageMap?

    /// The current text selection in reflowable content.
    @Published public internal(set) var selection: ReaderSelection?

    /// The measured height of the current reflowable document.
    @Published public internal(set) var contentHeight: Double

    /// Page indices currently visible in a fixed-page presentation.
    @Published public internal(set) var visiblePageIndices: [Int]

    /// Audiobook playback state, or `nil` for non-audio publications.
    @Published public internal(set) var playback: BookReaderPlaybackState?

    /// The most recent asynchronous presentation or playback error.
    @Published public internal(set) var lastError: BookError?

    /// Whether bitmap publications are presented as a two-page spread.
    @Published public var showsSpread: Bool

    /// A broadcast stream of edge-triggered reader events.
    ///
    /// Every subscriber first receives ``BookReaderEvent/ready`` and then its
    /// own copy of subsequent events.
    public var events: AsyncStream<BookReaderEvent> {
        let upstream = eventHub.stream()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            continuation.yield(.ready)
            let task = Task { @MainActor in
                for await event in upstream {
                    guard !Task.isCancelled else { break }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Whether this session presents an audiobook.
    public var isAudiobook: Bool {
        presentationEngine == .audio
    }

    /// Whether this publication supports two-page bitmap spreads.
    public var supportsSpreads: Bool {
        presentationEngine == .bitmapFixed
    }

    let presentationEngine: BookPresentationEngine
    let renderer: ContentRenderer
    let player: AudiobookPlayer?
    let eventHub = EventHub<BookReaderEvent>()
    var navigatorEventTask: Task<Void, Never>?
    var playbackEventTask: Task<Void, Never>?
    var viewportTask: Task<Void, Never>?
    var lastViewport: Viewport?

    #if canImport(WebKit)
    let reflowBridge: WebViewReflowBridge?
    #endif

    /// Opens a publication from a local or remote URL.
    public static func open(
        from url: URL,
        configuration: Configuration = Configuration()
    ) async throws -> BookReader {
        let book = try await Book.open(from: url, options: configuration.openOptions)
        return try await BookReader(book: book, configuration: configuration)
    }

    /// Opens a publication from an explicit source.
    public static func open(
        source: BookSource,
        configuration: Configuration = Configuration()
    ) async throws -> BookReader {
        let book = try await Book.open(source: source, options: configuration.openOptions)
        return try await BookReader(book: book, configuration: configuration)
    }

    /// Creates a reader for an already parsed publication.
    public init(
        book originalBook: Book,
        configuration: Configuration = Configuration()
    ) async throws {
        let book = Normalize.run(
            originalBook,
            allowsNetwork: configuration.openOptions.allowsNetwork
        )
        let presentationEngine = BookPresentationEngine(book: book)
        let reader = ReaderStateActor(
            book: book,
            stateStore: configuration.stateStore,
            preferences: configuration.preferences
        )

        #if canImport(WebKit)
        let bridge = presentationEngine.requiresReflowBridge
            ? WebViewReflowBridge(
                configuration: WebViewReflowConfiguration(plugins: configuration.plugins)
            )
            : nil
        reflowBridge = bridge
        #else
        let bridge: (any ReflowBridge)? = nil
        if presentationEngine.requiresReflowBridge {
            throw BookError.renderingFailed("WebKit is unavailable on this platform")
        }
        #endif

        let renderer = try ContentRenderer(
            book: book,
            reader: reader,
            options: configuration.openOptions,
            linkPolicy: configuration.linkPolicy,
            reflowBridge: bridge
        )
        let player = presentationEngine == .audio
            ? try AudiobookPlayer(
                book: book,
                options: configuration.openOptions,
                reader: reader,
                engine: configuration.audiobookEngine
            )
            : nil

        self.book = book
        self.presentationEngine = presentationEngine
        self.renderer = renderer
        self.player = player
        position = .start
        locator = book.locator(for: .start)
        preferences = configuration.preferences
        accessibility = configuration.accessibility
        bookmarks = []
        canGoBack = false
        canGoForward = false
        pageCount = renderer.pageCount()
        pageMap = renderer.pageMap()
        selection = nil
        contentHeight = 0
        visiblePageIndices = []
        playback = nil
        lastError = nil
        showsSpread = configuration.showsSpread

        startEventSubscriptions()

        do {
            if let player {
                try await player.prepare()
                if configuration.activatesRemoteCommands {
                    player.activateRemoteCommands(
                        skipInterval: configuration.remoteCommandSkipInterval
                    )
                }
                try await renderer.go(to: player.currentPosition())
            } else {
                try await renderer.restoreState()
            }
            try await renderer.setAccessibility(configuration.accessibility)
            await refreshState()
        } catch {
            navigatorEventTask?.cancel()
            playbackEventTask?.cancel()
            let bookError = BookError.from(error)
            lastError = bookError
            eventHub.yield(.error(bookError))
            throw bookError
        }
    }

    /// Stops session tasks and releases temporary playback resources.
    ///
    /// - Parameter removesTemporaryAudio: Whether extracted audiobook files
    ///   should be removed. The default is `true`.
    public func shutdown(removesTemporaryAudio: Bool = true) async {
        navigatorEventTask?.cancel()
        playbackEventTask?.cancel()
        viewportTask?.cancel()
        if let player {
            await player.shutdown(removesTemporaryAudio: removesTemporaryAudio)
        }
    }

}
