import Foundation

/// A snapshot of audiobook playback exposed by ``BookReader``.
public struct BookReaderPlaybackState: Sendable, Equatable {
    /// The current playback lifecycle state.
    public var status: AudiobookPlaybackStatus

    /// The current publication position, including its audio timestamp.
    public var position: Position

    /// The active playback rate.
    public var rate: Float

    /// The duration of the current track, when known.
    public var trackDuration: Double?

    /// Normalized progress through the complete audiobook.
    public var totalProgression: Double

    public init(
        status: AudiobookPlaybackStatus,
        position: Position,
        rate: Float,
        trackDuration: Double?,
        totalProgression: Double
    ) {
        self.status = status
        self.position = position
        self.rate = rate
        self.trackDuration = trackDuration
        self.totalProgression = totalProgression
    }

    init(_ snapshot: AudiobookPlaybackSnapshot) {
        self.init(
            status: snapshot.status,
            position: snapshot.position,
            rate: snapshot.rate,
            trackDuration: snapshot.trackDuration,
            totalProgression: snapshot.totalProgression
        )
    }
}

/// An edge-triggered event emitted by ``BookReader/events``.
///
/// Persistent state such as the current position and preferences is also
/// available through the reader's observable properties.
public enum BookReaderEvent: Sendable, Equatable {
    /// The event stream is ready for use.
    case ready

    case locatorChanged(Locator)

    case paginationChanged(PageMap)

    case selectionChanged(ReaderSelection)

    /// Reflowable content reported a new document height.
    case contentHeightChanged(Double)

    /// Back and forward navigation availability changed.
    case historyChanged(canGoBack: Bool, canGoForward: Bool)

    case preferencesChanged(ReaderPreferences)

    case accessibilityChanged(ReaderAccessibilitySettings)

    /// A publication or external link was activated.
    case linkActivated(url: URL, kind: LinkKind, action: LinkAction)

    /// The user activated a rendered decoration.
    case decorationTapped(DecorationTapEvent)

    /// A trusted reflow plug-in emitted a custom message.
    case bridgeMessage(name: String, payload: BridgeValue)

    case playbackChanged(BookReaderPlaybackState)

    case playbackTrackChanged(index: Int, title: String?)

    /// Audiobook playback reached the end of the publication.
    case playbackEnded

    case error(BookError)
}

public extension BookReader {
    /// Options used to open and operate a reader session.
    struct Configuration {
        /// Resource, network, and parser options used while opening the book.
        public var openOptions: OpenOptions

        /// Optional persistent storage for position, preferences, and bookmarks.
        public var stateStore: (any ReaderStateStore)?

        /// Policy used to classify and handle activated links.
        public var linkPolicy: any LinkPolicy

        /// Initial reading preferences, superseded by restored state when present.
        public var preferences: ReaderPreferences

        /// Initial accessibility behavior.
        public var accessibility: ReaderAccessibilitySettings

        /// Trusted scripts installed in reflowable publications.
        public var plugins: [ReflowScriptPlugin]

        /// Whether audiobook sessions register system remote commands.
        public var activatesRemoteCommands: Bool

        /// The skip interval registered with system remote commands.
        public var remoteCommandSkipInterval: Double

        /// Whether bitmap publications initially show a two-page spread.
        public var showsSpread: Bool

        var audiobookEngine: (any AudiobookPlaybackEngine)?

        public init(
            openOptions: OpenOptions = OpenOptions(),
            stateStore: (any ReaderStateStore)? = nil,
            linkPolicy: any LinkPolicy = DefaultLinkPolicy(),
            preferences: ReaderPreferences = .default,
            accessibility: ReaderAccessibilitySettings = .default,
            plugins: [ReflowScriptPlugin] = [],
            activatesRemoteCommands: Bool = true,
            remoteCommandSkipInterval: Double = 15,
            showsSpread: Bool = false
        ) {
            self.openOptions = openOptions
            self.stateStore = stateStore
            self.linkPolicy = linkPolicy
            self.preferences = preferences
            self.accessibility = accessibility
            self.plugins = plugins
            self.activatesRemoteCommands = activatesRemoteCommands
            self.remoteCommandSkipInterval = max(remoteCommandSkipInterval, 1)
            self.showsSpread = showsSpread
            audiobookEngine = nil
        }
    }
}
