# BookKit API

This guide covers the public integration path. View, renderer, WebKit, PDFKit,
and playback operations are main-actor isolated. Parsing and persistence use
Swift Concurrency.

## Installation

Until the first tagged release, depend on `main`:

```swift
dependencies: [
    .package(url: "https://github.com/wiedymi/swift-ebooks.git", branch: "main")
]
```

Add `.product(name: "BookKit", package: "swift-ebooks")` to the app target.

## Open a publication

```swift
import BookKit

let options = OpenOptions(allowsNetwork: false)
let book = try await Book.open(from: fileURL, options: options)

print(book.metadata.title)
print(book.format)
print(book.presentation.layout)
print(book.readingOrder.count)
```

Sources may be a URL, existing bytes, or a deferred provider:

```swift
let fromData = try await Book.open(
    source: .data(payload, fileName: "novel.epub")
)

let fromProvider = try await Book.open(
    source: .stream(fileName: "novel.fb2") {
        try loadPublicationData()
    }
)
```

The provider defers loading but the current parser still materializes the whole
source. It is not an incremental byte stream.

## Open options

```swift
let options = OpenOptions(
    allowsNetwork: false,
    tempDirectory: appTemporaryDirectory,
    fileAccess: SandboxFileAccessPolicy(),
    maxSourceBytes: 512 * 1024 * 1024,
    maxResourceBytes: 64 * 1024 * 1024,
    maxArchiveUncompressedBytes: 1024 * 1024 * 1024,
    maxArchiveEntries: 10_000
)
```

| Option | Purpose |
| --- | --- |
| `allowsNetwork` | Allows explicit HTTP(S) sources/resources and remote audiobook tracks; false by default |
| `tempDirectory` | App-owned location for audio inspection/materialization |
| `fileAccess` | Security-scoped or custom URL access policy |
| `maxSourceBytes` | Maximum source before parsing |
| `maxResourceBytes` | Maximum individual archive/resource/decoded page buffer |
| `maxArchiveUncompressedBytes` | Aggregate archive expansion limit |
| `maxArchiveEntries` | Archive, component, and relevant decoder-record count limit |

## Select a presentation path

The normalized model declares `.reflowable`, `.fixed`, or `.audiobook`. PDF is a
fixed publication with a dedicated native view. A fixed EPUB can be direct image
pages or XHTML that still needs the reflow bridge.

```swift
func isBitmapFixed(_ book: Book) -> Bool {
    book.presentation.layout == .fixed &&
        !book.readingOrder.isEmpty &&
        book.readingOrder.allSatisfy {
            $0.resourceID != nil && $0.mediaType?.hasPrefix("image/") == true
        }
}

@MainActor
func makeRenderer(book: Book, options: OpenOptions) throws
    -> (ContentRenderer, WebViewReflowBridge?)
{
    let needsBridge = book.format != .pdf &&
        book.presentation.layout != .audiobook &&
        !isBitmapFixed(book)
    let bridge = needsBridge ? WebViewReflowBridge() : nil
    let renderer = try ContentRenderer(
        book: book,
        options: options,
        reflowBridge: bridge
    )
    return (renderer, bridge)
}
```

`ContentRenderer.mode` reports `.reflow`, `.fixed`, `.pdf`, or `.audio`.

## Reflowable and XHTML fixed-layout books

Render once the host knows the viewport:

```swift
try await renderer.renderChapter(
    at: position.spineIndex,
    viewport: Viewport(width: 390, height: 844),
    theme: .light,
    typography: .default
)

if let bridge {
    BookView(bridge: bridge)
}
```

On resize, capture and restore the position:

```swift
let position = await renderer.currentPosition()
let preferences = await renderer.preferences()

try await renderer.renderChapter(
    at: position.spineIndex,
    viewport: newViewport,
    theme: preferences.theme,
    typography: preferences.typography
)
try await renderer.go(to: position)
```

## Fixed image pages

CBZ, image-only/fixed EPUB, and DjVu use `FixedPageBookView`:

```swift
FixedPageBookView(
    book: book,
    pageIndex: position.spineIndex,
    showsSpread: true,
    onLinkActivated: { activation in
        Task { @MainActor in
            try await renderer.handlePageLink(
                activation.link,
                onPageAt: activation.pageIndex
            )
        }
    },
    onVisibilityChanged: { visibility in
        position = visibility.locator.position
        visiblePages = visibility.pageIndices
    }
) { context in
    ZStack(alignment: .topLeading) {
        ForEach(context.presentation.links) { link in
            let frame = context.frame(for: link.bounds)
            Rectangle()
                .stroke(.blue, lineWidth: 1)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }

        NarrationFocusOverlay(
            pageIndex: context.pageIndex,
            pageFrame: context.imageFrame,
            sourceSize: context.sourceSize
        )
    }
    .allowsHitTesting(false)
}
```

The overlay is host-owned. It can show narration focus, OCR regions, annotations,
coordinates, debug bounds, or live position UI. `frame(for:)` maps top-left-origin
source-pixel bounds into the aspect-fitted page. `hitFrame(for:)` also expands
thin regions to an accessible target size.

Use the adapter without SwiftUI when needed:

```swift
let adapter = FixedPageAdapter(book: book)
let page = adapter.position(forPageIndex: 12)
let spreads = adapter.spreads()
let image = adapter.asset(forPageIndex: 12)
```

Thumbnails and bounded prefetch:

```swift
let store = ImagePageStore(book: book, maxThumbnailCacheBytes: 32 * 1024 * 1024)
let thumbnailPNG = try await store.thumbnail(forPageIndex: 12, maxPixelSize: 320)
await store.prefetch(aroundPageIndex: 12, distance: 2)
```

## PDF

The parser retains the unencrypted source as asset `pdf-document`:

```swift
if let data = book.assets.first(where: { $0.id == "pdf-document" })?.data {
    PDFBookView(
        data: data,
        pageIndex: position.spineIndex,
        onPageChanged: { index in
            Task { @MainActor in
                try await renderer.go(
                    to: Position(spineIndex: index, progression: 0)
                )
            }
        },
        onLinkActivated: { url in
            routePDFURLThroughAppPolicy(url)
        }
    )
}
```

PDFKit keeps internal page actions. URL annotations are intercepted, do not use
PDFKit's implicit system opener, and are delivered to the host. `PDFBookView` is
unavailable on tvOS; parsing, normalized text, TOC, and `PDFPageAdapter` remain
available.

## Audiobooks

`ContentRenderer` can expose track navigation, but actual playback is owned by
`AudiobookPlayer`:

```swift
let player = try AudiobookPlayer(
    book: book,
    options: options,
    stateStore: stateStore
)

try await player.prepare()
player.activateRemoteCommands(skipInterval: 15)
try await player.play()
player.setRate(1.25)
```

Navigation and seeking:

```swift
try await player.seek(toTimestamp: 90)
_ = try await player.nextTrack()
_ = try await player.previousTrack(restartsAfter: 5)

if let item = book.tableOfContents.first,
   let locator = book.locator(forNavigationHref: item.href)
{
    try await player.seek(to: locator.position)
}
```

Media fragments such as `#t=12.5` and `#t=npt:01:10` become timestamps.

Subscribe before `prepare()` when the host needs the initial ready event:

```swift
let events = player.events
Task { @MainActor in
    for await event in events {
        switch event {
        case let .positionChanged(snapshot):
            updateTime(snapshot.position.timestamp)
            updateProgress(snapshot.totalProgression)
        case let .trackChanged(index, title):
            showTrack(index, title)
        case let .error(error):
            show(error)
        default:
            break
        }
    }
}
```

Call `await player.shutdown()` when the session ends. It pauses, persists,
unregisters remote commands, clears Now Playing, and removes temporary audio.

## Positions, locators, and TOC

`Position` is persistence-oriented. `Locator` adds href and total publication
progress:

```swift
let position = await renderer.currentPosition()
let locator = await renderer.currentLocator()

try await renderer.go(to: position)
try await renderer.go(to: locator)

if let destination = book.tableOfContents.first {
    try await renderer.go(to: destination)
}
```

`TOCNode` is recursive. Use `node.flattened` only for flat UI/search; keep
`children` for a hierarchical outline. Hrefs are resolved against the reading
order and may contain anchors or audio timestamps.

## Visual navigator events

Every `renderer.events` access returns a fresh buffered stream:

```swift
let events = renderer.events
Task { @MainActor in
    for await event in events {
        switch event {
        case let .locatorChanged(locator):
            updateProgress(locator.totalProgression)
        case let .paginationChanged(pageMap):
            updatePageCount(pageMap.pageCount)
        case let .selectionChanged(selection):
            showSelection(selection.text)
        case let .historyChanged(back, forward):
            updateHistoryButtons(back: back, forward: forward)
        case let .linkActivated(url, kind, action):
            handleLinkEvent(url, kind: kind, action: action)
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

Cancel the consuming task when its model/screen is released.

## Page and jump history

```swift
try await renderer.nextPage()
try await renderer.previousPage()

if renderer.canGoBack() {
    _ = try await renderer.goBack()
}
if renderer.canGoForward() {
    _ = try await renderer.goForward()
}
```

Reflow uses measured `PageMap` values. PDF/fixed use page indexes. Audio mode uses
track indexes; `AudiobookPlayer` supplies time-based movement.

## Preferences and accessibility

```swift
try await renderer.setPreferences(
    ReaderPreferences(
        readingMode: .paginated,
        theme: .dark,
        typography: Typography(fontSize: 20, lineHeight: 1.65)
    )
)

try await renderer.setAccessibility(
    ReaderAccessibilitySettings(
        isVoiceOverEnabled: voiceOverIsRunning,
        forceScrollWhenVoiceOverEnabled: true,
        prefersReducedMotion: reduceMotionIsEnabled,
        announcesPositionChanges: voiceOverIsRunning
    )
)
```

The host owns platform accessibility observation. BookKit can temporarily use
scroll mode for VoiceOver without overwriting the saved preference.

## Persistence and bookmarks

```swift
let store = FileReaderStateStore(directory: stateDirectory)
let renderer = try ContentRenderer(
    book: book,
    stateStore: store,
    reflowBridge: bridge
)

try await renderer.restoreState()
let bookmark = try await renderer.addBookmark(note: "Important")
try await renderer.updateBookmark(id: bookmark.id, note: "Review later")
try await renderer.removeBookmark(id: bookmark.id)
```

`AudiobookPlayer` exposes equivalent add/update/remove/list bookmark methods and
stores the current timestamp.

## Decorations and narration

Reflow decorations are grouped so search, highlighting, and text-to-speech state
can update independently:

```swift
let marker = Decoration(
    id: "tts-current",
    group: .tts,
    locator: paragraphLocator,
    style: .default(for: .tts)
)

try await renderer.setDecorations([marker], in: .tts)
try await renderer.clearDecorations(in: .tts)
```

DOM decorations require an anchor. Fixed publications use the SwiftUI overlay
builder instead; the host can map its own OCR/text regions through
`FixedPageOverlayContext`.

## Link policy

```swift
struct AppLinkPolicy: LinkPolicy {
    func action(for url: URL, context: LinkContext) async -> LinkAction {
        switch url.scheme?.lowercased() {
        case "http", "https": return .openExternally
        case "bookkit", nil: return .follow
        default: return .block
        }
    }
}
```

Inject it into `ContentRenderer`. `.openExternally` emits an event; BookKit does
not call the system URL opener. Use `handlePageLink` for `PageLink` values from
fixed pages. For PDF, pass `onLinkActivated` and apply the same application policy.

## Trusted WebKit extensions

`ReflowScriptPlugin` provides typed app-owned DOM behavior. Plug-ins can register
commands, post events, and observe content/position/selection/link hooks. They run
in the client content world and must never be sourced from an ebook.

See [`BRIDGE_EXTENSIONS.md`](BRIDGE_EXTENSIONS.md).

## DRM/protected content

All supported formats are DRM-free only. There is no password or license API.
Catch the typed error to explain the result:

```swift
do {
    let book = try await Book.open(from: fileURL)
    present(book)
} catch let BookError.protectedContent(protection) {
    showUnsupportedProtection(
        kind: protection.kind,
        scheme: protection.scheme,
        resource: protection.resource
    )
}
```

BookKit rejects encrypted ZIP, non-font-obfuscation EPUB encryption, Kindle
encryption, every encrypted PDF, protected audio, and Secure DjVu.

## Search and diagnostics

```swift
let results = try await book.search("chapter five")
if let first = results.first {
    try await renderer.go(to: first.position)
}

for diagnostic in book.diagnostics {
    print(diagnostic.severity, diagnostic.code, diagnostic.message)
}
```

Search returns the first match per matching section. Diagnostics represent
recoverable parser concerns; blocking failures use `BookError`.

For format-specific limits, read
[`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md).
