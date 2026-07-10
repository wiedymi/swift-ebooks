# swift-ebooks

[![GitHub](https://img.shields.io/badge/-GitHub-181717?style=flat-square&logo=github&logoColor=white)](https://github.com/wiedymi)
[![Twitter](https://img.shields.io/badge/-Twitter-1DA1F2?style=flat-square&logo=twitter&logoColor=white)](https://x.com/wiedymi)
[![Email](https://img.shields.io/badge/-Email-EA4335?style=flat-square&logo=gmail&logoColor=white)](mailto:contact@wiedymi.com)
[![Discord](https://img.shields.io/badge/-Discord-5865F2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/zemMZtrkSb)
[![Support me](https://img.shields.io/badge/-Support%20me-ff69b4?style=flat-square&logo=githubsponsors&logoColor=white)](https://github.com/sponsors/vivy-company)

Native Swift parsing, navigation, and presentation for DRM-free books on Apple
platforms.

BookKit opens EPUB, FB2, MOBI, AZW3/KF8, PDF, CBZ, DjVu, TXT, HTML,
Markdown, and audiobooks through one normalized publication model. It includes
reflow and fixed-page navigators, live locators, hierarchical navigation,
persistence, host-controlled links, accessibility support, and a typed bridge for
trusted app features such as narration or reading analytics.

## Status

The supported paths are implemented end to end and covered by 150 automated
tests. The suite includes real WebKit integration, AVFoundation playback,
archive/protection checks, fixed-page link geometry, and clean-room DjVu decoder
fixtures.

See [`docs/IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md) for the exact
support matrix and known compatibility boundaries.

## Features

- One `Book` model and `ContentRenderer` navigator across visual formats
- EPUB 2 NCX and EPUB 3 nav, nested TOC, landmarks, and page lists
- Reflowable and pre-paginated/image-only EPUB
- CBZ natural ordering, `ComicInfo.xml`, manga RTL, covers, spreads, thumbnails,
  and prefetching
- Clean-room DjVu BZZ/ZP, IW44, JB2, MMR, palette, text, outline, and link support
- W3C/Readium and packaged audiobooks plus MP3, M4A/M4B, and AAC playback
- TXT, HTML, and Markdown import adapters with generated navigation
- Live `AsyncStream` events for location, pagination, selection, links, and state
- Position restore, timestamps, bookmarks, preferences, and jump history
- VoiceOver-aware reflow, reduced motion, and accessible fixed-page link targets
- Host overlays for narration focus, annotations, live coordinates, or custom UI
- Typed app-to-JavaScript commands and JavaScript-to-app events
- Offline defaults, publication-script sanitization, and bounded resource loading
- SwiftUI views for WebKit, PDFKit, and bitmap/fixed-page publications
- A reference app that exercises every presentation path

## Format support

| Format | Supported path |
| --- | --- |
| EPUB 2/3 | Reflowable and pre-paginated spine, image-only books, metadata, NCX/nav, TOC, landmarks, page list, CSS, fonts, and embedded resources |
| FB2 / `.fb2.zip` | Structured metadata, semantic sections, nested TOC, notes, styles, binary images, and a safe single-document ZIP adapter |
| MOBI 6 | Uncompressed/PalmDOC text, EXTH metadata, file-position links, guide/TOC recovery, and images |
| AZW3/KF8 | Unencrypted PalmDOC/FDST flows, chapters, styles, metadata, and embedded images |
| PDF | PDFKit metadata/text, outline and page-list navigation, live page callbacks, and policy-controlled URL annotations |
| CBZ | Image pages, natural ordering, ComicInfo metadata/bookmarks, cover and spread detection, LTR/RTL manga layout, thumbnails, and prefetch |
| DjVu | Single/bundled pages, shared dictionaries, BZZ/ZP, IW44, JB2, MMR, JPEG layers, palettes, rotation, OCR text, outlines, and map-area links |
| TXT | Unicode text converted into safe reflowable HTML |
| HTML | Heading-derived nested TOC with active content sanitized before rendering |
| Markdown | Headings, lists, links, emphasis, quotes, and code converted to safe HTML with a nested TOC |
| Audiobook | W3C/Readium JSON manifests, packaged audiobooks, MP3/M4A/M4B/AAC, chapters, media fragments, playback, rates, Now Playing, and remote commands |

CBR is intentionally not supported. DjVu is implemented inside BookKit and does
not embed or link DjVuLibre.

## DRM-free only

BookKit never decrypts a publication, accepts a password/key, or attempts to
circumvent access controls. It rejects:

- encrypted ZIP entries;
- EPUB encryption other than standard IDPF font obfuscation;
- encrypted Kindle records;
- every encrypted PDF, including files PDFKit might otherwise unlock;
- protected audiobook manifests and AVFoundation protected assets;
- Secure DjVu containers.

Using PDFKit, WebKit, ImageIO, or AVFoundation is only a rendering/playback step
after BookKit's protection checks. A protected file fails with
`BookError.protectedContent`, including the detected scheme/resource when known.

## Platforms

- iOS 16+
- macOS 13+
- tvOS 16+
- visionOS 1+
- Swift tools 6.2+

`PDFBookView` is available on iOS, macOS, and visionOS. Parsing/navigation remain
available on tvOS for a host-provided PDF surface.

Remote audiobook tracks are rejected on visionOS because the platform does not
expose a reliable protected-content inspection result there. Local and packaged
DRM-free audio remain supported.

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

## Opening and navigating

```swift
import BookKit

let options = OpenOptions(allowsNetwork: false)
let book = try await Book.open(from: fileURL, options: options)
let store = FileReaderStateStore(directory: readerStateDirectory)

let needsWebView = book.format != .pdf &&
    book.presentation.layout != .audiobook &&
    !(book.presentation.layout == .fixed &&
      book.readingOrder.allSatisfy { $0.resourceID != nil && $0.mediaType?.hasPrefix("image/") == true })

let bridge = needsWebView ? WebViewReflowBridge() : nil
let renderer = try ContentRenderer(
    book: book,
    options: options,
    stateStore: store,
    reflowBridge: bridge
)

try await renderer.restoreState()
try await renderer.go(to: book.tableOfContents.first ?? book.pageList.first!)
```

For a reflowable or XHTML fixed-layout publication:

```swift
if let bridge {
    BookView(bridge: bridge)
}
```

For PDF:

```swift
PDFBookView(
    data: pdfData,
    pageIndex: position.spineIndex,
    onPageChanged: updatePage,
    onLinkActivated: routeThroughAppLinkPolicy
)
```

For CBZ, image-only/fixed EPUB, or DjVu:

```swift
FixedPageBookView(
    book: book,
    pageIndex: position.spineIndex,
    showsSpread: true,
    onLinkActivated: { activation in
        Task {
            try await renderer.handlePageLink(
                activation.link,
                onPageAt: activation.pageIndex
            )
        }
    },
    onVisibilityChanged: { visibility in
        showProgress(visibility.locator)
    }
) { context in
    NarrationOverlay(
        page: context.pageIndex,
        pageFrame: context.imageFrame,
        mapSourceBounds: context.frame(for:)
    )
}
```

`ImagePageStore` provides bounded thumbnail caching and neighboring-page
prefetching for those bitmap publications.

## Audiobooks

`AudiobookPlayer` owns time-based playback independently from the visual
renderer:

```swift
let player = try AudiobookPlayer(
    book: book,
    options: options,
    stateStore: store
)

try await player.prepare()
player.activateRemoteCommands()
try await player.play()
try await player.seek(to: tocLocator.position)
player.setRate(1.25)
```

Playback events contain track-local timestamps and duration-weighted publication
progress. `shutdown()` persists the current position, removes temporary audio,
and unregisters remote commands.

## Live events and links

Every access to `renderer.events` creates an independent event stream:

```swift
let events = renderer.events

Task { @MainActor in
    for await event in events {
        switch event {
        case let .locatorChanged(locator):
            showProgress(locator.totalProgression)
        case let .selectionChanged(selection):
            showSelection(selection.text)
        case let .linkActivated(url, _, action):
            handle(url, action: action)
        default:
            break
        }
    }
}
```

Internal destinations use native navigation. External URLs are blocked by
default; an injected `LinkPolicy` can return `.openExternally`, after which the
host remains responsible for presenting or opening the URL.

## Bridge customization

Trusted host scripts run in `WKContentWorld.defaultClient`, isolated from
publication JavaScript while sharing the rendered DOM:

```swift
let plugin = ReflowScriptPlugin(
    identifier: "com.example.reader.speech",
    source: """
    window.BookKit.registerCommand('speech.focus', payload => {
      document.getElementById(payload.anchor)?.scrollIntoView();
      return { focused: payload.anchor };
    });

    window.BookKit.on('positionChanged', position => {
      window.BookKit.post('speech.position', position);
    });
    """
)

let bridge = WebViewReflowBridge(
    configuration: WebViewReflowConfiguration(plugins: [plugin])
)
```

See [`docs/BRIDGE_EXTENSIONS.md`](docs/BRIDGE_EXTENSIONS.md) for the complete
command, event, lifecycle, and security contract.

## Validation

```bash
git submodule update --init --recursive
./scripts/verify_corpus.sh
swift test
swift build -c release
```

The reference app supports file import and deterministic launch checks:

```bash
swift run BookKitExample
swift run BookKitExample --demo tests/corpus/files/epictetus.epub
```

## Docs

- [`docs/API.md`](docs/API.md) — integration and public surfaces
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — parser, navigator, and view ownership
- [`docs/IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md) — tested support matrix and boundaries
- [`docs/TEST_COVERAGE.md`](docs/TEST_COVERAGE.md) — automated evidence and release checks
- [`docs/SPEC.md`](docs/SPEC.md) — product invariants and acceptance criteria
- [`docs/BRIDGE_EXTENSIONS.md`](docs/BRIDGE_EXTENSIONS.md) — trusted WebKit extensions
- [`docs/REFERENCE_SURVEY.md`](docs/REFERENCE_SURVEY.md) — implementation references and licensing notes

## License

MIT
