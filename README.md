# swift-ebooks

BookKit parses and presents DRM-free books on Apple platforms through one
`BookReader` session and `BookReaderView`.

Supports EPUB, FB2, MOBI, AZW3/KF8, PDF, CBZ, DjVu, TXT, HTML, Markdown, and
audiobooks. See [format support and limits](docs/IMPLEMENTATION_STATUS.md).
CBR and DRM decryption are not supported.

Requires Swift 6.2+, iOS 16+, macOS 13+, tvOS 16+, or visionOS 1+.
PDFKit presentation is unavailable on tvOS; normalized PDF text remains available.

## Install

Until the first tagged release:

```swift
dependencies: [
    .package(url: "https://github.com/wiedymi/swift-ebooks.git", branch: "main")
]
```

Add `.product(name: "BookKit", package: "swift-ebooks")` to your target.

## Open and present

```swift
import BookKit

let reader = try await BookReader.open(from: fileURL)
```

```swift
BookReaderView(reader: reader)
```

For persistence:

```swift
let reader = try await BookReader.open(
    from: fileURL,
    configuration: .init(
        stateStore: FileReaderStateStore(directory: stateDirectory)
    )
)
```

Network access is off by default. External links require host policy.

## Navigate and play

```swift
try await reader.next()
try await reader.previous()
try await reader.go(to: tableOfContentsItem)
try await reader.goBack()

// Audiobooks
try await reader.play()
try await reader.pause()
try await reader.seek(toTimestamp: 90)
try reader.setPlaybackRate(1.25)

await reader.shutdown()
```

Observe reader properties for position, preferences, bookmarks, and playback.
Use `reader.events` for links, script messages, and errors. Call `shutdown()` when
the session ends to remove remote commands and temporary audio files.

For parsing without UI:

```swift
let book = try await Book.open(from: fileURL)
print(book.metadata.title)
```

## Validate

```bash
git submodule update --init --recursive
./scripts/verify_corpus.sh
swift test
swift build -c release
swift run BookKitExample --demo tests/corpus/files/epictetus.epub
```

See [validation](docs/TEST_COVERAGE.md) for CI and platform checks, and
[API examples](docs/API.md) for configuration, links, accessibility, and scripts.
The [documentation index](docs/README.md) covers architecture and contracts.

## License and contact

MIT. DjVu is implemented without embedding or linking DjVuLibre.

[GitHub](https://github.com/wiedymi) · [X](https://x.com/wiedymi) ·
[Email](mailto:contact@wiedymi.com) · [Discord](https://discord.gg/zemMZtrkSb) ·
[Support](https://github.com/sponsors/vivy-company)
