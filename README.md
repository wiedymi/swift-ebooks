# swift-ebooks

[![GitHub](https://img.shields.io/badge/-GitHub-181717?style=flat-square&logo=github&logoColor=white)](https://github.com/wiedymi)
[![Twitter](https://img.shields.io/badge/-Twitter-1DA1F2?style=flat-square&logo=twitter&logoColor=white)](https://x.com/wiedymi)
[![Email](https://img.shields.io/badge/-Email-EA4335?style=flat-square&logo=gmail&logoColor=white)](mailto:contact@wiedymi.com)
[![Discord](https://img.shields.io/badge/-Discord-5865F2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/zemMZtrkSb)
[![Support me](https://img.shields.io/badge/-Support%20me-ff69b4?style=flat-square&logo=githubsponsors&logoColor=white)](https://github.com/sponsors/vivy-company)

Native Swift ebook parsing, navigation, and rendering for Apple platforms.

BookKit opens EPUB 2/3, FB2, MOBI, unencrypted AZW3/KF8, and PDF through one
normalized model and navigator API. Reflowable content renders with WebKit,
PDF uses PDFKit, and publication content stays offline and script-free by default.

## Status

The core reader works end to end for the repository corpus, including hierarchical
navigation, internal links, measured pagination, live positions, persistence,
accessibility, and host-defined JavaScript extensions.

See [`docs/IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md) for the tested
support matrix and explicit format limits. In particular, fixed-layout EPUB, media
overlays, canonical EPUB CFI generation, HUFF/CDIC, DRM, and complete proprietary
KF8 reconstruction are not currently supported.

## Features

- One `Book` model for EPUB, FB2, MOBI, AZW3/KF8, and PDF
- EPUB 3 navigation documents and EPUB 2 NCX fallback
- Hierarchical table of contents, landmarks, page lists, and publication links
- Scroll and measured paginated reading modes
- Live `AsyncStream` events for location, pagination, selection, links, and content size
- Position restore, bookmarks, preferences, and bounded jump history
- Highlights, search markers, and text-to-speech decorations
- Typed app-to-JavaScript commands and JavaScript-to-app events
- VoiceOver-aware layout, reduced-motion support, and live position announcements
- Active-content sanitization and explicit network/resource limits
- SwiftUI wrappers for WebKit content and native PDF pages
- A complete SwiftUI reference client in `BookKitExample`

## Format Support

| Format | Supported path |
| --- | --- |
| EPUB 2/3 | Reflowable spine, metadata, NCX/nav, TOC, landmarks, page list, CSS, and embedded resources |
| FB2 | Structured metadata, semantic sections, nested TOC, notes, styles, and binary images |
| MOBI 6 | Uncompressed/PalmDOC text, EXTH metadata, file-position links, guide/TOC, and images |
| AZW3/KF8 | Unencrypted PalmDOC/FDST flows, chapters, styles, metadata, and embedded images |
| PDF | Metadata, text/page ingestion, outline TOC, page navigation, and native PDFKit view |

## Platforms

- iOS 16+
- macOS 13+
- tvOS 16+
- visionOS 1+
- Swift tools 6.2+

`PDFBookView` is available on iOS, macOS, and visionOS. PDF parsing and page
navigation remain available on tvOS for a host-provided presentation surface.

## Installation

Add BookKit to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/wiedymi/swift-ebooks.git", branch: "main")
]
```

Then add the library product to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "BookKit", package: "swift-ebooks")
    ]
)
```

## Quick Start

Open a publication, create the appropriate renderer, and render its first section:

```swift
import BookKit
import Foundation

@MainActor
func makeReader(at url: URL) async throws
    -> (book: Book, renderer: ContentRenderer, bridge: WebViewReflowBridge?)
{
    let options = OpenOptions(allowsNetwork: false)
    let book = try await Book.open(from: url, options: options)
    let bridge = book.format == .pdf ? nil : WebViewReflowBridge()
    let renderer = try ContentRenderer(
        book: book,
        options: options,
        reflowBridge: bridge
    )

    if !book.readingOrder.isEmpty {
        try await renderer.renderChapter(
            at: 0,
            viewport: Viewport(width: 390, height: 844)
        )
    }

    return (book, renderer, bridge)
}
```

For reflowable books, attach the bridge to SwiftUI:

```swift
BookView(bridge: bridge)
```

For PDF, drive the page index through `ContentRenderer` and present the retained
document asset:

```swift
if let data = book.assets.first(where: { $0.id == "pdf-document" })?.data {
    PDFBookView(data: data, pageIndex: position.spineIndex)
}
```

## Navigation and Live Events

Each access to `renderer.events` creates an independent event stream:

```swift
let events = renderer.events

Task { @MainActor in
    for await event in events {
        switch event {
        case let .locatorChanged(locator):
            print("Book progress:", locator.totalProgression)
        case let .selectionChanged(selection):
            print("Selected:", selection.text)
        case let .linkActivated(url, _, action):
            print("Link:", url, action)
        default:
            break
        }
    }
}
```

Use the same navigator for page movement, TOC entries, and jump history:

```swift
try await renderer.nextPage()
try await renderer.go(to: book.tableOfContents[0])
_ = try await renderer.goBack()
```

See [`docs/API.md`](docs/API.md) for locators, persistence, decorations, link
policy, accessibility, and PDF behavior.

## Bridge Customization

Host scripts run with BookKit in `WKContentWorld.defaultClient`, isolated from
publication-page JavaScript while still sharing the rendered DOM:

```swift
let plugin = ReflowScriptPlugin(
    identifier: "com.example.reader",
    source: """
    window.BookKit.registerCommand('speech.focus', payload => {
      document.getElementById(payload.anchor)?.scrollIntoView();
      return { focused: payload.anchor };
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
    payload: .object(["anchor": .string("paragraph-12")])
)
```

Custom plug-in messages arrive as `NavigatorEvent.bridgeMessage`. The complete
bridge contract is documented in [`docs/BRIDGE_EXTENSIONS.md`](docs/BRIDGE_EXTENSIONS.md).

## Running Tests

Initialize the reference submodules and verify the real-book corpus:

```bash
git submodule update --init --recursive
./scripts/verify_corpus.sh
swift test
```

Build the release configuration:

```bash
swift build -c release
```

## Example App

`BookKitExample` is a SwiftUI reference client with file import, hierarchical
navigation, live reader telemetry, persistence, bookmarks, accessibility syncing,
custom bridge commands, and native PDF pages.

```bash
swift run BookKitExample
```

For deterministic launch checks, bypass the file picker:

```bash
swift run BookKitExample --demo tests/corpus/files/epictetus.epub
```

The process prints `BOOKKIT_EXAMPLE_READY` after the publication has opened.

## Docs

- [`docs/README.md`](docs/README.md) - documentation index
- [`docs/API.md`](docs/API.md) - opening, rendering, navigation, state, and host policies
- [`docs/BRIDGE_EXTENSIONS.md`](docs/BRIDGE_EXTENSIONS.md) - isolated JavaScript plug-ins and typed messages
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) - parsing, normalization, rendering, and event ownership
- [`docs/IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md) - tested support matrix and known limits
- [`docs/TEST_COVERAGE.md`](docs/TEST_COVERAGE.md) - automated validation and corpus strategy
- [`docs/SPEC.md`](docs/SPEC.md) - v1 scope, invariants, and acceptance criteria
- [`docs/REFERENCE_SURVEY.md`](docs/REFERENCE_SURVEY.md) - permissive-license implementation references

## Repository Notes

- `refs/` contains upstream projects as git submodules for architecture and behavior study.
- The implementation is MIT-licensed and does not copy or mechanically port reference code.
- Publication scripts are disabled; host plug-ins are trusted app code installed separately.
- DRM decryption is intentionally out of scope.

## License

MIT
