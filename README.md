# swift-ebooks

[![GitHub](https://img.shields.io/badge/-GitHub-181717?style=flat-square&logo=github&logoColor=white)](https://github.com/wiedymi)
[![Twitter](https://img.shields.io/badge/-Twitter-1DA1F2?style=flat-square&logo=twitter&logoColor=white)](https://x.com/wiedymi)
[![Email](https://img.shields.io/badge/-Email-EA4335?style=flat-square&logo=gmail&logoColor=white)](mailto:contact@wiedymi.com)
[![Discord](https://img.shields.io/badge/-Discord-5865F2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/zemMZtrkSb)
[![Support me](https://img.shields.io/badge/-Support%20me-ff69b4?style=flat-square&logo=githubsponsors&logoColor=white)](https://github.com/sponsors/vivy-company)

Native Swift parsing, navigation, playback, and presentation for DRM-free books
on Apple platforms.

BookKit opens EPUB, FB2, MOBI, AZW3/KF8, PDF, CBZ, DjVu, TXT, HTML,
Markdown, and audiobooks through one `BookReader` session and one
`BookReaderView`. Format-specific WebKit, PDFKit, bitmap, and AVFoundation
engines stay behind that API.

## Status

The supported paths are implemented end to end and covered by automated tests,
including WebKit integration, AVFoundation playback, archive/protection checks,
fixed-page links, and clean-room DjVu decoder fixtures.

See [`docs/IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md) for exact
compatibility boundaries.

## Features

- One observable `BookReader` for opening, navigation, persistence, and playback
- One `BookReaderView` for reflow, PDF, bitmap pages, and audiobooks
- EPUB 2 NCX and EPUB 3 navigation, landmarks, page lists, CSS, and fonts
- CBZ covers, spreads, manga RTL, thumbnails, and prefetching
- Clean-room DjVu BZZ/ZP, IW44, JB2, MMR, text, outline, and link support
- W3C/Readium and packaged audiobooks plus MP3, M4A/M4B, and AAC playback
- TXT, HTML, and Markdown import adapters with generated navigation
- Observable location, history, preferences, bookmarks, selection, and playback
- Host-controlled external links, accessibility, decorations, and trusted scripts
- Offline defaults, script sanitization, and bounded resource loading

## Format support

| Format | Supported path |
| --- | --- |
| EPUB 2/3 | Reflowable, pre-paginated, image-only, metadata, navigation, CSS, fonts, and resources |
| FB2 / `.fb2.zip` | Sections, nested TOC, notes, styles, and binary images |
| MOBI 6 | PalmDOC text, metadata, file-position links, guide/TOC, and images |
| AZW3/KF8 | Unencrypted PalmDOC/FDST flows, chapters, styles, metadata, and images |
| PDF | PDFKit rendering, outline, page list, text, and policy-controlled URL annotations |
| CBZ | Natural ordering, ComicInfo, manga RTL, covers, spreads, links, and thumbnails |
| DjVu | Bundled pages, shared dictionaries, raster layers, OCR, outlines, and links |
| TXT / HTML / Markdown | Safe reflowable HTML with generated navigation |
| Audiobook | Manifests, packages, audio files, chapters, playback, rates, and Now Playing |

CBR is intentionally unsupported. DjVu is implemented in BookKit without
embedding or linking DjVuLibre.

## DRM-free only

BookKit never decrypts publications or accepts passwords or keys. It rejects
encrypted ZIP entries, unsupported EPUB encryption, encrypted Kindle records,
all encrypted PDFs, protected audiobook assets, and Secure DjVu containers with
`BookError.protectedContent`.

## Platforms

- iOS 16+
- macOS 13+
- tvOS 16+
- visionOS 1+
- Swift tools 6.2+

PDFKit presentation is unavailable on tvOS; parsing and normalized PDF text
remain available there.

## Installation

Until the first tagged release, depend on `main`:

```swift
dependencies: [
    .package(url: "https://github.com/wiedymi/swift-ebooks.git", branch: "main")
]
```

Then add `.product(name: "BookKit", package: "swift-ebooks")` to your target.

## Open and present any publication

```swift
import BookKit

let reader = try await BookReader.open(from: fileURL)
```

```swift
BookReaderView(reader: reader)
```

BookKit selects and owns the appropriate rendering or playback engine. The host
does not inspect formats, create a WebKit bridge, extract PDF assets, or forward
fixed-page callbacks.

Configure persistence and policies at open time:

```swift
let reader = try await BookReader.open(
    from: fileURL,
    configuration: .init(
        openOptions: OpenOptions(allowsNetwork: false),
        stateStore: FileReaderStateStore(directory: stateDirectory),
        linkPolicy: AppLinkPolicy()
    )
)
```

## Navigation and state

`BookReader` is an `ObservableObject`. Its state is immediately usable by
SwiftUI controls:

```swift
Text(reader.book.metadata.title)
ProgressView(value: reader.locator.totalProgression)

Button("Previous") { Task { try await reader.previous() } }
Button("Next") { Task { try await reader.next() } }
Button("Back") { Task { try await reader.goBack() } }

try await reader.go(to: reader.book.tableOfContents[0])
```

Observable properties include `position`, `locator`, `preferences`, `bookmarks`,
history availability, pagination, selection, visible pages, playback, and errors.

## Audiobooks

`BookReaderView` supplies default audiobook controls. Custom controls use the
same reader:

```swift
try await reader.play()
try await reader.pause()
try await reader.seek(toTimestamp: 90)
try await reader.skip(by: 15)
try reader.setPlaybackRate(1.25)

if let playback = reader.playback {
    print(playback.status, playback.totalProgression)
}
```

Call `await reader.shutdown()` when the session ends to remove remote commands
and temporary audio resources.

## Events, links, and extensions

Most UI should observe reader properties. `reader.events` is a broadcast stream
for edge-triggered events such as links, decoration taps, plug-in messages,
playback completion, and errors.

External URLs remain host decisions through `LinkPolicy`. Trusted WebKit scripts
can be installed through `BookReader.Configuration.plugins` and invoked through
`reader.callBridgeCommand`.

See [`docs/BRIDGE_EXTENSIONS.md`](docs/BRIDGE_EXTENSIONS.md) for the isolated
host-script contract.

## Parsing without UI

The normalized `Book` model remains independently available for import,
indexing, conversion, or server-side workflows:

```swift
let book = try await Book.open(from: fileURL)
print(book.metadata.title)
```

Advanced parser overrides, fixed-page/PDF adapters, and specialized views remain
available for hosts that intentionally replace the default presentation.

## Validation

```bash
git submodule update --init --recursive
./scripts/verify_corpus.sh
swift test
swift build -c release
```

The reference app uses the unified API:

```bash
swift run BookKitExample
swift run BookKitExample --demo tests/corpus/files/epictetus.epub
```

## Documentation

- [`docs/API.md`](docs/API.md) — unified session API and advanced customization
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — ownership and internal engines
- [`docs/IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md) — tested support matrix
- [`docs/TEST_COVERAGE.md`](docs/TEST_COVERAGE.md) — automated evidence
- [`docs/SPEC.md`](docs/SPEC.md) — product invariants
- [`docs/BRIDGE_EXTENSIONS.md`](docs/BRIDGE_EXTENSIONS.md) — trusted WebKit extensions

## License

MIT
