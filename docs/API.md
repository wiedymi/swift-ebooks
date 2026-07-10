# BookKit API

This guide covers the public integration path. All renderer and WebKit bridge
operations are main-actor isolated. Parsing and state persistence use Swift
Concurrency and do not require the caller to block the main thread.

## Installation

Until the first tagged release, depend on `main`:

```swift
dependencies: [
    .package(url: "https://github.com/wiedymi/swift-ebooks.git", branch: "main")
]
```

Add `.product(name: "BookKit", package: "swift-ebooks")` to the app target.

## Opening a publication

`Book.open` detects the format from the file name and content signature, selects
the parser, and returns the normalized cross-format `Book` model.

```swift
import BookKit
import Foundation

let book = try await Book.open(from: fileURL)

print(book.metadata.title)
print(book.format)
print(book.readingOrder.count)
```

The supported source shapes are URL, in-memory data, and a synchronous data
provider:

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

The stream provider avoids requiring the data before `Book.open` is called, but
the current parser pipeline still materializes the complete source as `Data`.
It is not an incremental byte stream.

## Open options

BookKit is offline by default and wraps user-selected URLs with
`SandboxFileAccessPolicy`.

```swift
let options = OpenOptions(
    allowsNetwork: false,
    tempDirectory: nil,
    fileAccess: SandboxFileAccessPolicy(),
    maxSourceBytes: 512 * 1024 * 1024,
    maxResourceBytes: 64 * 1024 * 1024,
    maxArchiveUncompressedBytes: 1024 * 1024 * 1024
)

let book = try await Book.open(from: fileURL, options: options)
```

| Option | Purpose |
| --- | --- |
| `allowsNetwork` | Allows explicit HTTP(S) source/resource loading. It is `false` by default. |
| `tempDirectory` | Reserved app-owned temporary location for parser/host use. |
| `fileAccess` | Controls security-scoped or custom file access. |
| `maxSourceBytes` | Rejects an oversized source before parsing. |
| `maxResourceBytes` | Rejects an oversized individual resource. |
| `maxArchiveUncompressedBytes` | Limits total uncompressed EPUB entries. |

To provide a different security-scoped or app-group policy, implement
`FileAccessPolicy` and inject it through `OpenOptions`.

## Constructing a renderer

Reflowable formats require a `ReflowBridge`. The built-in implementation owns a
`WKWebView` and installs BookKit in an isolated WebKit content world.

```swift
@MainActor
func makeRenderer(book: Book, options: OpenOptions) throws
    -> (ContentRenderer, WebViewReflowBridge?)
{
    let bridge = book.format == .pdf ? nil : WebViewReflowBridge()
    let renderer = try ContentRenderer(
        book: book,
        options: options,
        reflowBridge: bridge
    )
    return (renderer, bridge)
}
```

Render a reflow section after the host knows its viewport:

```swift
try await renderer.renderChapter(
    at: 0,
    viewport: Viewport(width: 390, height: 844),
    theme: .light,
    typography: .default
)
```

On resize, capture the current position before rendering again, then restore it:

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

This prevents rotation or window resizing from resetting the reading location.

## SwiftUI presentation

Present reflowable content with the bridge retained by the host model:

```swift
if let bridge {
    BookView(bridge: bridge)
}
```

`BookView` is a thin SwiftUI wrapper around the bridge's `WKWebView`. The host
still owns toolbars, gestures, TOC UI, settings, and state display.

For PDF on iOS, macOS, or visionOS, use the retained document asset and the
current page index:

```swift
if let data = book.assets.first(where: { $0.id == "pdf-document" })?.data {
    PDFBookView(data: data, pageIndex: position.spineIndex)
}
```

`PDFBookView` is not defined on tvOS. Hosts can use the normalized page text and
`PDFPageAdapter` with their own tvOS presentation surface.

## Live events

`ContentRenderer.events` is a broadcast source: every access returns a fresh,
buffered `AsyncStream`. Create one stream per independent consumer.

```swift
let events = renderer.events

Task { @MainActor in
    for await event in events {
        switch event {
        case .ready:
            break
        case let .locatorChanged(locator):
            updateProgress(locator.totalProgression)
        case let .paginationChanged(pageMap):
            updatePageCount(pageMap.pageCount)
        case let .selectionChanged(selection):
            showSelection(selection.text)
        case let .contentHeightChanged(height):
            updateContentHeight(height)
        case let .historyChanged(canGoBack, canGoForward):
            updateHistoryButtons(back: canGoBack, forward: canGoForward)
        case let .bridgeMessage(name, payload):
            handlePluginMessage(name: name, payload: payload)
        case let .error(error):
            showReaderError(error)
        default:
            break
        }
    }
}
```

Cancel the consuming task when the screen/model is released. The stream also
finishes when its event owner is released.

## Positions and locators

`Position` is the persistence-oriented value. `Locator` adds section href and
total-publication progression for presentation and navigation.

```swift
let position = await renderer.currentPosition()
let locator = await renderer.currentLocator()

try await renderer.go(to: position)
try await renderer.go(to: locator)
```

Built-in positions use section index, section progression, and an optional DOM
anchor. `cfi` is accepted and preserved, but BookKit does not generate canonical
EPUB CFIs yet.

## Page, TOC, and history navigation

```swift
try await renderer.nextPage()
try await renderer.previousPage()

if let chapter = book.tableOfContents.first {
    try await renderer.go(to: chapter)
}

if renderer.canGoBack() {
    _ = try await renderer.goBack()
}
```

Reflow page movement uses the measured `PageMap` and crosses section boundaries.
PDF page movement uses the PDF page index. TOC hrefs are resolved relative to the
publication spine and may include anchors.

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

The host owns platform accessibility observation. When configured, BookKit can
temporarily use scroll mode for VoiceOver without overwriting the user's saved
paginated preference.

## State and bookmarks

Use `FileReaderStateStore` for app-owned JSON persistence or implement
`ReaderStateStore` for another backend.

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

After `restoreState`, read the restored position/preferences, render that section,
and call `go(to:)`. The complete sequence is implemented in
`Examples/BookKitExample/main.swift`.

## Decorations

Decorations are grouped so search, highlighting, and text-to-speech state can be
updated independently.

```swift
let locator = await renderer.currentLocator()
let marker = Decoration(
    id: "tts-current",
    group: .tts,
    locator: locator,
    style: .default(for: .tts)
)

try await renderer.setDecorations([marker], in: .tts)
try await renderer.clearDecorations(in: .tts)
```

DOM-backed decoration rendering currently requires a locator anchor. Taps arrive
as `NavigatorEvent.decorationTapped`.

## Link policy

Internal anchors and spine links follow the built-in native navigation path.
External links are blocked by `DefaultLinkPolicy`.

```swift
struct AppLinkPolicy: LinkPolicy {
    func action(for url: URL, context: LinkContext) async -> LinkAction {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return .openExternally
        case "bookkit", nil:
            return .follow
        default:
            return .block
        }
    }
}
```

Inject the policy into `ContentRenderer`. When the action is `.openExternally`,
BookKit emits `NavigatorEvent.linkActivated`; the host remains responsible for
presenting or opening the URL.

## Search

```swift
let results = try await book.search("chapter five")
if let first = results.first {
    try await renderer.go(to: first.position)
}
```

Search currently returns the first match in each matching section. It is an
in-memory normalized-content search, not a persisted full-text index.

## Errors and diagnostics

Thrown failures use `BookError`, including unsupported format, I/O, malformed
document, missing asset, navigation, and rendering failures.

Parser warnings that do not prevent opening are stored in `book.diagnostics`:

```swift
for diagnostic in book.diagnostics {
    print(diagnostic.severity, diagnostic.code, diagnostic.message)
}
```

For exact per-format limits, use [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md).
