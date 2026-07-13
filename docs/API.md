# BookKit API

BookKit has two entry points:

- `BookReader` and `BookReaderView` for a complete app reading session;
- `Book.open` for parsing and normalized publication data without UI.

The primary API hides WebKit, PDFKit, bitmap, and AVFoundation engine selection.
All session and view operations are main-actor isolated. Parsing and persistence
use Swift Concurrency.

## Open a reader

```swift
let reader = try await BookReader.open(from: fileURL)
```

Existing data and deferred providers are also accepted:

```swift
let fromData = try await BookReader.open(
    source: .data(payload, fileName: "novel.epub")
)

let fromProvider = try await BookReader.open(
    source: .dataProvider(fileName: "novel.fb2") {
        try loadPublicationData()
    }
)
```

The provider defers loading but currently materializes the complete source.

An already parsed or programmatically constructed model can start a session:

```swift
let reader = try await BookReader(book: book)
```

## Configuration

```swift
let configuration = BookReader.Configuration(
    openOptions: OpenOptions(
        allowsNetwork: false,
        tempDirectory: appTemporaryDirectory,
        fileAccess: SandboxFileAccessPolicy(),
        maxSourceBytes: 512 * 1024 * 1024,
        maxResourceBytes: 64 * 1024 * 1024,
        maxArchiveUncompressedBytes: 1024 * 1024 * 1024,
        maxArchiveEntries: 10_000
    ),
    stateStore: FileReaderStateStore(directory: stateDirectory),
    linkPolicy: AppLinkPolicy(),
    preferences: .default,
    accessibility: .default,
    plugins: [],
    activatesRemoteCommands: true,
    remoteCommandSkipInterval: 15,
    showsSpread: false
)

let reader = try await BookReader.open(
    from: fileURL,
    configuration: configuration
)
```

Network access is off by default. Source, resource, archive, and decoder bounds
are enforced before ordinary rendering or playback.

## Present every format

```swift
BookReaderView(reader: reader)
```

That one view provides:

- WebKit reflow and XHTML fixed-layout presentation;
- bitmap pages and spreads for CBZ, DjVu, and image-only EPUB;
- native PDFKit presentation where available, with a text fallback on tvOS;
- default audiobook playback controls.

It also owns viewport rerendering, swipe navigation, PDF page synchronization,
fixed-page visibility, link forwarding, and audiobook scrubbing. Hosts do not
need to branch on `Book.format` or `BookPresentation.layout`.

## Observable state

`BookReader` conforms to `ObservableObject` and exposes read-only published state:

| Property | Meaning |
| --- | --- |
| `book` | Normalized immutable publication model |
| `position` | Persistence-oriented section/page/track position |
| `locator` | Position plus href and total publication progression |
| `preferences` | Reading mode, theme, and typography |
| `accessibility` | Effective accessibility configuration |
| `bookmarks` | Persisted bookmarks |
| `canGoBack`, `canGoForward` | Jump-history availability |
| `pageCount`, `pageMap` | Current pagination information |
| `selection` | Current reflow selection |
| `contentHeight` | Current reflow content height |
| `visiblePageIndices` | Visible fixed-page indexes |
| `playback` | Audiobook state, or `nil` for visual books |
| `lastError` | Most recently reported engine error |

`showsSpread` is writable and updates `BookReaderView` directly. The capability
properties `isAudiobook` and `supportsSpreads` help hosts conditionally show
format-appropriate controls without selecting an engine.

## Navigation

```swift
try await reader.next()
try await reader.previous()
try await reader.go(to: position)
try await reader.go(to: locator)
try await reader.go(to: tableOfContentsItem)

_ = try await reader.goBack()
_ = try await reader.goForward()
```

The same methods navigate chapters, fixed pages, PDF pages, and audiobook tracks.
Audiobook destinations containing timestamps seek playback as part of the same
operation.

`Position` is designed for persistence. `Locator` adds the section href and total
publication progression. `TOCNode` preserves hierarchical navigation through
`children`; `flattened` is available for flat UI.

## Preferences and accessibility

```swift
try await reader.setReadingMode(.paginated)
try await reader.setTheme(.dark)
try await reader.setTypography(
    Typography(fontFamily: "New York", fontSize: 20, lineHeight: 1.6)
)

try await reader.setAccessibility(
    ReaderAccessibilitySettings(
        isVoiceOverEnabled: true,
        forceScrollWhenVoiceOverEnabled: true,
        prefersReducedMotion: false,
        announcesPositionChanges: true
    )
)
```

`setPreferences` applies all reading preferences in one operation. Preference
changes use the same shared state owner for visual books and audiobooks.

## Persistence and bookmarks

BookKit includes in-memory and file-backed state stores. Apps can implement
`ReaderStateStore` for a database, app group, or cloud service.

```swift
let bookmark = try await reader.addBookmark(note: "Important")
try await reader.updateBookmark(id: bookmark.id, note: "Review")
try await reader.removeBookmark(id: bookmark.id)
```

Snapshots contain the position, preferences, bookmarks, and update time. A
reader session has one shared state owner even when the selected engine is audio.

## Audiobook playback

When `reader.playback` is non-`nil`, the same reader also provides:

```swift
try await reader.play()
try await reader.pause()
try await reader.seek(toTimestamp: 90)
try await reader.skip(by: -15)
try reader.setPlaybackRate(1.25)
```

`BookReaderPlaybackState` contains status, current position, rate, track duration,
and duration-weighted total progression. Remote commands and Now Playing are
activated by configuration and removed by:

```swift
await reader.shutdown()
```

`shutdown` also persists the final position and removes temporary audio unless
requested otherwise.

## Events

Published properties are the primary state API. Each access to `reader.events`
creates an independent broadcast stream for edge-triggered integration work:

```swift
let events = reader.events

Task { @MainActor in
    for await event in events {
        switch event {
        case let .linkActivated(url, _, .openExternally):
            open(url)
        case let .bridgeMessage(name, payload):
            handlePluginMessage(name, payload)
        case let .error(error):
            show(error)
        default:
            break
        }
    }
}
```

`BookReaderEvent` also reports locators, pagination, selection, history,
preferences, accessibility, decoration taps, playback changes, track changes,
and playback completion.

## Links

Internal destinations navigate natively. External URLs are blocked by default.
Inject a `LinkPolicy` to classify URLs:

```swift
struct AppLinkPolicy: LinkPolicy {
    func action(for url: URL, context: LinkContext) async -> LinkAction {
        switch url.scheme?.lowercased() {
        case "http", "https": .openExternally
        case "bookkit", nil: .follow
        default: .block
        }
    }
}
```

`BookReaderView` routes PDF and fixed-page links through the configured policy.
The host remains responsible for opening `.openExternally` URLs after receiving
the event.

## Decorations and trusted scripts

```swift
try await reader.setDecorations(highlights, in: .highlight)
try await reader.clearDecorations(in: .highlight)
```

Trusted host scripts run in WebKit's isolated client content world:

```swift
let plugin = ReflowScriptPlugin(
    identifier: "com.example.reader.speech",
    source: """
    window.BookKit.registerCommand('speech.focus', payload => {
      document.getElementById(payload.anchor)?.scrollIntoView();
      return { focused: payload.anchor };
    });
    """
)

let reader = try await BookReader.open(
    from: fileURL,
    configuration: .init(plugins: [plugin])
)

let result = try await reader.callBridgeCommand(
    "speech.focus",
    payload: .object(["anchor": .string("paragraph-12")])
)
```

See `BRIDGE_EXTENSIONS.md` for lifecycle and security details.

## Parsing without a reader

Use the parser-only entry point when no reading session is needed:

```swift
let book = try await Book.open(from: fileURL)
let fromData = try await Book.open(
    source: .data(payload, fileName: "novel.epub")
)
```

The normalized model contains metadata, reading order, assets, navigation,
presentation hints, diagnostics, and stable identifiers.

`ParserRegistry` and `BookParser` remain available for overriding recognized
format parsers. Fixed-page/PDF adapters and specialized views remain advanced
surfaces for hosts that intentionally replace the default presentation.

## Search and diagnostics

```swift
let index = SearchIndex(book: reader.book)
let results = index.search("example")

for diagnostic in reader.book.diagnostics {
    print(diagnostic.severity, diagnostic.code, diagnostic.message)
}
```

Malformed or protected content throws `BookError`. Recoverable parser issues are
reported through `Book.diagnostics`.
