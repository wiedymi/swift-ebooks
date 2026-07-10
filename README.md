# swift-ebooks

Direct Swift ebook parsing, processing, navigation, and rendering for Apple platforms.
Sandbox-compatible and offline by default.

## Current status

The core reader is usable end to end, with explicit limits documented in
[`docs/IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md). Highlights:

- EPUB 2 NCX and EPUB 3 navigation documents, including hierarchical TOC,
  landmarks, page lists, linked stylesheets, and embedded resources
- structured FB2 metadata, semantic body markup, nested TOC, notes, styles, and binaries
- real PalmDOC/MOBI decompression, EXTH metadata, file-position links, images,
  and KF8 FDST content/style flows (with documented proprietary-format limits)
- PDFKit-backed text/page ingestion, outline navigation, page lists, and native PDF rendering
- one `Navigator` API for locators, measured page navigation, jump history,
  preferences, bookmarks, decorations, selections, and live events
- an isolated, typed JavaScript extension boundary with custom commands,
  events, lifecycle hooks, and host `WKWebViewConfiguration` customization
- offline-by-default rendering, active-content sanitization, and configurable size limits

v1.0 formats in scope:

- EPUB 2/3
- FB2
- MOBI
- AZW3/KF8 (unencrypted)
- PDF (read-only adapter)

## Bootstrap references

```bash
git submodule update --init --recursive
```

## Test Corpus

Open end-to-end parser assets are defined in `tests/corpus/manifest.tsv`.

```bash
git submodule update --init --recursive
./scripts/verify_corpus.sh
```

Run unit + E2E tests:

```bash
swift test
```

## Example App

`BookKitExample` is a SwiftUI reference client, not a static parser demo. It includes:

- real-time locator, pagination, selection, link, and plug-in events (no polling)
- hierarchical TOC, landmarks, and page-list navigation
- automatic VoiceOver/reduced-motion synchronization
- scroll/paginated modes, measured next/previous page movement, and jump history
- persistent position, preferences, and bookmarks
- a sample isolated JavaScript plug-in command and lifecycle event
- native PDF pages and reflowable WebKit content

Build/run:

```bash
swift run BookKitExample
```

For automated/demo launches, open a book without the file picker:

```bash
swift run BookKitExample --demo tests/corpus/files/epictetus.epub
```

## Bridge customization

```swift
let plugin = ReflowScriptPlugin(
    identifier: "com.example.reader",
    source: """
    window.BookKit.registerCommand('speech.focus', payload => {
      document.querySelector(`[data-word="${payload.index}"]`)?.scrollIntoView();
      return { focused: payload.index };
    });
    window.BookKit.on('selectionChanged', selection => {
      window.BookKit.post('speech.selection', selection);
    });
    """
)

let bridge = WebViewReflowBridge(
    configuration: WebViewReflowConfiguration(plugins: [plugin])
)
let renderer = try ContentRenderer(book: book, reflowBridge: bridge)

let reply = try await renderer.callBridgeCommand(
    "speech.focus",
    payload: .object(["index": .number(12)])
)
```

BookKit code runs in `WKContentWorld.defaultClient`; publication scripts cannot
read or replace its bridge globals. Plug-ins are app code and share that isolated world.

You can also open the package in Xcode and run the `BookKitExample` scheme.

## License

MIT (`LICENSE`), with upstream licenses preserved in each `refs/*` submodule.
