# BookKit API

BookKit has two entry points:

- `BookReader` and `BookReaderView` for a complete app reading session;
- `Book.open` for parsing and normalized publication data without UI.

Session and view operations run on `@MainActor`. Parsing runs off the main actor;
persistence is actor-owned.

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

Providers return complete `Data`; their allocations cannot be limited by BookKit.
File and network sources enforce byte limits during reads.

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

The view selects the engine and handles viewport, page, link, and playback callbacks.

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
| `selection` | Current reflow or native PDF selection |
| `decorations` | Active highlight, search, and speech marks |
| `speech` | Observable speech controller, created when first used |
| `contentHeight` | Current reflow content height |
| `visiblePageIndices` | Visible fixed-page indexes |
| `playback` | Audiobook state, or `nil` for visual books |
| `lastError` | Most recently reported engine error |

`showsSpread` is writable and updates `BookReaderView` directly. The capability
properties `isAudiobook`, `supportsSpreads`, and `capabilities` help hosts show
supported controls. A supported text feature can still have no text in an image-only book.

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
`Theme.customCSS` updates the open chapter and is removed when the theme changes.
Exact location jumps are immediate; the navigation call does not leave a scroll
animation in progress.

`BookReaderView` follows system VoiceOver and reduced-motion settings by default.
Use `observesSystemAccessibility: false` when the app supplies those settings.
VoiceOver is the system screen reader; the speech API below is a separate feature.

## Persistence and bookmarks

BookKit includes in-memory and file-backed state stores. Apps can implement
`ReaderStateStore` for a database, app group, or cloud service.

```swift
let bookmark = try await reader.addBookmark(note: "Important")
try await reader.updateBookmark(id: bookmark.id, note: "Review")
try await reader.removeBookmark(id: bookmark.id)
```

Snapshots contain position, preferences, bookmarks, and update time. File stores
use fixed-length hashed names and can read older state files. Scroll position is
saved after 300 ms without a new position event. Saves run in order.

```swift
try await reader.saveState() // Throws storage errors; the app can retry.
await reader.shutdown()     // Saves, stops speech, and reports errors in lastError.
```

`BookReaderView` also saves when the scene becomes inactive. Apps with a custom
view must call `saveState()` before backgrounding and `shutdown()` when closing.

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

## Search and highlights

```swift
let results = try await reader.search(
    "example", options: SearchOptions(diacriticSensitive: false, maximumResults: 500)
)
if let result = results.first {
    try await reader.go(to: result.position)
}

let marks = try await reader.highlightSelection(
    style: DecorationStyle(backgroundColor: "#ffe58f", underlineColor: "#b26a00")
)
let savedData = try JSONEncoder().encode(marks)
// Store savedData in the app's annotation store.

let restored = try JSONDecoder().decode([Decoration].self, from: savedData)
try await reader.setDecorations(restored, in: .highlight)
try await reader.clearDecorations(in: .highlight)
try await reader.clearSelection()
```

Search returns all non-overlapping matches up to the requested limit, with real
text previews. `Book.search` and `SearchIndex.find` use the same matching rules.
`Book.search` runs off the main actor and supports task cancellation. The optional
synchronous `SearchIndex` retains extracted text; build it off the main actor.

HTML extraction decodes entities and excludes markup, scripts, metadata, hidden
attributes, and common inline hidden styles. It does not evaluate external CSS.
Image-only pages have no searchable text unless the publication supplies OCR.

`Position.textRange` and `Locator.textRange` contain UTF-16 offsets in normalized
chapter text, the exact quote, and nearby text. Native reflow and PDF rendering
use these fields to locate a sentence across elements or line breaks. Changed
text is searched again using its context; an ambiguous match is not used.
This is not a canonical EPUB CFI API.

`ReaderSelection.locators` contains all selected ranges, including multiple PDF
pages. `highlightSelection` returns one `Decoration` per range. The app stores
these values with its notes and restores them with `setDecorations`.
`ReaderSelection.range.bounds` is in content-view coordinates, in points.

The `.highlight`, `.search`, and `.tts` groups are independent. Overlapping reflow
styles use that order, with speech last. Applying marks preserves text selection
and publisher styles. PDF supports background and underline marks with `#RGB`,
`#RRGGBB`, or `#RRGGBBAA` colors; it does not recolor printed text. Bitmap pages
use `fixedPageOverlay` for app-supplied regions.

## Speech and dubbing

```swift
reader.speech.highlightStyle = DecorationStyle(backgroundColor: "#d0ebff")
reader.speech.followsText = true
reader.speech.highlightsText = true
reader.speech.continuesAcrossSections = true
reader.speech.start(options: SpeechOptions(language: "en-US", rate: 0.45))
reader.speech.pause()
reader.speech.resume()
reader.speech.stop()
```

Observe `speech.state`, `speech.currentText`, and `speech.spokenLocation`. The last
property contains the current word or phrase when the engine reports it. Default
marks cover the current sentence. Set `highlightsText` to false and apply your own
marks from `spokenLocation` for different behavior. Controls observe the speech
controller itself, as shown in the example app.

Speech starts at the sentence containing the supplied locator, current selection,
or current reading position. Long sentences are split into at most 2,000 UTF-16
units. `SystemReaderSpeechEngine.availableVoices` lists installed voices; pass a
voice's identifier in `SpeechOptions`. Missing requested voices or languages fail
with an error. The app controls its audio session and background-audio capability.
`SystemReaderSpeechEngine(usesApplicationAudioSession: false)` instead lets the
system manage a separate speech audio session on iOS, tvOS, and visionOS.

For a custom voice or recorded dub, inject a session-owned `ReaderSpeechEngine`
through `Configuration.speechEngine`. Its `speak` call must remain active until
playback ends, and must finish on stop or cancellation. Word callbacks use UTF-16
offsets in the supplied text. Remote service access belongs to that engine.

An app can also drive its own player without implementing a speech engine:

```swift
let parts = try await reader.book.readingText(inSection: 0, maximumUTF16Length: 1_000)
// Each part has text and a source locator for the app's voice or translation service.
if let cue = parts.first {
    try await reader.showSpokenText(cue.locator, followsText: true)
}
```

## Custom view controls

```swift
BookReaderView(reader: reader, pageTurnGesture: .disabled)
    .selectionActions { selection in
        Button("Read from here") { reader.speech.start(from: selection.locator) }
    }
    .fixedPageOverlay { page in
        Text("Page \(page.pageIndex + 1)")
            .position(x: page.imageFrame.midX, y: page.imageFrame.minY + 20)
    }
```

Selection controls appear at the bottom of the view; system copy controls remain
available. Your app supplies their labels, style, and actions. Automatic page
swipes are disabled during selection, scrolling mode, and VoiceOver. Explicit
`.swipe` enables swipes in scrolling mode; `.disabled` leaves page turning to the app.

`Configuration.configureWebView` and the view's `configurePDFView` modifier allow
native setup. Preserve BookKit's delegates and scripts. Custom parsers can be
passed directly in `Configuration.parserRegistry`.

## Trusted scripts

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

See [bridge extensions](BRIDGE_EXTENSIONS.md) for hooks and script contracts.

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

## Diagnostics

Malformed or protected content throws `BookError`. Recoverable parser issues are
reported through `Book.diagnostics`. Presentation, storage, and speech errors are
also available through `reader.lastError` and the event stream.
