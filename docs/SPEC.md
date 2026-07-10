# Swift BookKit Spec (v1.0)

> Implementation note: this is the architecture target. See
> [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) for the tested support
> matrix and explicit remaining limits.

Date: 2026-02-22

## 1. Objective

Build a Swift package that provides one direct API for:

- Parsing ebook formats (`.epub`, `.fb2`, `.mobi`, extensible for more)
- Processing content into a normalized internal book model
- Rendering flow/paginated reading views for Apple platforms
- Running safely inside app sandbox environments by default

Target package name: `BookKit`

## 2. Non-Goals (v1.0 MVP)

- DRM decryption (LCP, Kindle DRM, Adobe DRM)
- Full authoring/export pipeline
- OCR or scanned-PDF reconstruction

## 3. Supported Formats Roadmap

MVP (v1.0):

- EPUB 2/3 (container + OPF + spine + nav/toc + resources)
- FB2 (metadata + body + sections + inline resources)
- MOBI (metadata + content extraction where available)
- AZW3/KF8 (unencrypted content only)
- PDF (read-only page/text ingestion adapter)

Next:

- Additional document formats (post-v1)

## 4. Design Principles

- Single core model: one `Book` type independent of source format.
- Pluggable parsers: each format in separate module; common parser protocol.
- Streaming + memory safety: parse lazily where possible for large books.
- Deterministic normalization: stable HTML/CSS/document model output.
- UI-decoupled rendering core: layout engine separate from SwiftUI/UIKit wrappers.
- Short API names: avoid repeating `ebook`/`unified` in every type.
- Sandbox-first I/O: all disk/network access is explicit and injectable.

## 5. Package Layout

```text
Sources/
  BookKit/
    Book.swift
    Metadata.swift
    ReadingOrder.swift
    Asset.swift
    TOC.swift
    Position.swift
    BookError.swift
  BookParsers/
    BookParser.swift
    ParserRegistry.swift
    Detection/
      FormatSniffer.swift
    EPUB/
      EPUBParser.swift
    FB2/
      FB2Parser.swift
    MOBI/
      MOBIParser.swift
    AZW3/
      AZW3Parser.swift
    PDF/
      PDFAdapter.swift
  BookPipeline/
    Normalize.swift
    SanitizeContent.swift
    ResolveLinks.swift
    ResolveStyles.swift
    SearchIndex.swift
  BookRenderer/
    Layout/
      ReflowLayout.swift
      FixedLayout.swift
    Reader/
      Reader.swift
      Theme.swift
      Typography.swift
    PDF/
      PDFPageAdapter.swift
  BookUI/
    SwiftUI/
      BookView.swift
      PageView.swift
Tests/
  ... mirrored by module ...
```

## 6. Core Protocols and Types

### 6.1 Parser Protocol

```swift
public protocol BookParser {
    static var formats: [BookFormat] { get }
    func parse(source: BookSource, options: OpenOptions) async throws -> Book
}
```

`BookSource` must support sandbox-safe inputs:

- in-memory data (`Data`)
- app-container file URL
- security-scoped file URL (user-selected external files)
- stream/handle-based source for low-memory + extension-safe execution

### 6.2 Book Model

`Book` includes:

- `id`, `format`, `version`
- `metadata` (title, authors, language, identifiers, publisher, dates)
- `readingOrder` (`[Chapter]`)
- `assets` (images, styles, fonts, media)
- `tableOfContents` (`[TOCNode]`)
- `landmarks` / `pageList` when available
- `rawExtensions` for format-specific data (namespaced)

### 6.3 Position Model

`Position` for cross-format reading position:

- `spineIndex`
- `progression` (0...1 within spine item)
- `cfi` (EPUB optional)
- `fragment` (DOM id / anchor)
- `textContext` (prefix/suffix for robust re-anchoring)

## 7. Parsing and Normalization Pipeline

1. Format detection (`magic bytes` + extension + signature files)
2. Container extraction:
   - EPUB: ZIP + `META-INF/container.xml` + OPF
   - FB2: XML parse + binary objects extraction
   - MOBI: PalmDB records + metadata/content records
   - AZW3/KF8: container records + content/resources (unencrypted only)
   - PDF: document catalog/pages + text layer extraction (when present)
3. Intermediate conversion to normalized content documents (`XHTML/HTML-like`)
4. Resource graph build (href/media-type map, manifest IDs, fallback chain)
5. Metadata harmonization into common schema
6. TOC and landmarks normalization
7. Validation warnings collection (`BookDiagnostics`)

## 8. Rendering Architecture

### 8.1 Rendering Modes

- Reflowable mode: chapter-level pagination with theme/typography controls
- Fixed-layout mode: page-as-canvas rendering path for fixed EPUB content
- PDF mode: page-based navigation via PDF adapter

### 8.2 Rendering Components

- `Reader` actor: owns book state, reading progression, bookmarks
- `ReflowLayout`: computes page breaks from viewport + typography config
- `ContentRenderer`: renders normalized docs through `WKWebView` in v1.0 (EPUB/FB2/MOBI/AZW3)
- `PDFPageAdapter`: renders PDF pages and maps page index <-> `Position`
- `ResourceLoader`: async fetch/caching for images/fonts/css/media

### 8.3 UI Wrappers

- SwiftUI `BookView`
- UIKit bridge for host apps requiring `UIViewController` integration

### 8.4 Navigator API (v1)

- Single cross-format navigator surface with stable methods/events.
- Standard location object: `Locator(sectionIndex, sectionProgression, totalProgression, anchor, cfi)`.
- Flow controls:
  - `setReadingMode(.scroll | .paginated)` (runtime switch)
  - `go(to: Locator)`, `goBack()`, `goForward()`
- Decorations:
  - grouped markers (`highlight`, `search`, `tts`)
  - tap callback/event channel for host integrations
- Preferences/state persistence per book:
  - last position
  - reading mode
  - theme
  - typography
  - bookmarks
- Accessibility API:
  - host-provided `ReaderAccessibilitySettings`
  - VoiceOver override support (`forceScrollWhenVoiceOverEnabled`)

## 9. Concurrency and Threading

- Use Swift Concurrency for all I/O and parsing.
- Isolate mutable shared state in actors (`Reader`, cache/index stores).
- Keep parser implementations `Sendable` where possible.
- Avoid main-thread blocking to prevent extension/app watchdog terminations.

## 10. Error Model

Public error families:

- `BookError.unsupportedFormat`
- `BookError.invalidContainer`
- `BookError.malformedDocument`
- `BookError.missingAsset`
- `BookError.renderingFailed`

All parse and rendering operations also emit structured diagnostics:

- `severity`: info/warning/error
- `code`: stable machine-readable identifier
- `location`: file/resource + line/offset when available

## 11. Testing Strategy

### 11.1 Unit Tests

- Parser correctness per format for metadata/spine/toc/resource mapping
- Normalization idempotence and deterministic output snapshots
- Position round-trip tests

### 11.2 Integration Tests

- Golden book corpus:
  - EPUB2 sample
  - EPUB3 nav sample
  - FB2 with footnotes/images
  - MOBI sample with chapters and cover
  - AZW3/KF8 sample (unencrypted)
  - PDF sample (text layer + image-heavy)
- Canonical open corpus manifest: `tests/corpus/manifest.tsv`
- Corpus integrity gate: `scripts/verify_corpus.sh` must pass in CI

### 11.3 Performance Tests

- Parse latency and peak memory benchmarks for small/medium/large books
- Pagination throughput (cold/hot cache)

## 12. Security and Content Safety

- Sanitize active content (`script`, inline event handlers, unsafe URLs)
- Restrict file/resource access to book sandbox
- Validate media types and content lengths before decode
- Add size limits and recursion guards for malformed archives/XML
- Prevent ZIP/XML path traversal (`../`) and symlink escape attacks
- Deny implicit outbound network fetches unless host app opts in

## 13. Implementation Phases

1. Core model + parser registry + format detector
2. EPUB parser MVP + normalized book output
3. FB2 parser MVP
4. MOBI parser MVP
5. AZW3/KF8 parser MVP (unencrypted only)
6. PDF ingestion adapter MVP
7. Reflow renderer MVP + PDF page adapter (SwiftUI wrapper)
8. Diagnostics/indexing/bookmarks/annotations

## 14. Compatibility Statement

Library license target: MIT.

Reference projects in `refs/` are permissive-licensed (MIT/BSD/Apache) and used for architecture and behavior comparison. Any direct code reuse must preserve original notices and comply with each upstream license terms.

## 15. API DX Naming Rules

- Prefer one domain word: `Book`, not `BookPublication`.
- Avoid repeated qualifiers in type names; keep detail in module paths.
- Use verbs for entrypoints: `Book.open(...)`, `Reader.go(...)`.
- Keep format names explicit only where needed: `EPUBParser`, `FB2Parser`.
- No legacy `Ebook*` aliases in v1.0 public API.

## 16. Proposed Public API Shape

```swift
import BookKit

let options = OpenOptions(
    allowsNetwork: false,
    tempDirectory: nil,
    fileAccess: SandboxFileAccessPolicy()
)

let book = try await Book.open(from: fileURL, options: options)
let reader = Reader(book: book)

try await reader.go(to: .start)
let current = await reader.position

let results = try await book.search("chapter 5")
```

## 17. Sandbox Compatibility Requirements

Target environments:

- iOS/iPadOS app sandbox
- macOS App Sandbox
- App extensions (Share, File Provider, Widgets where feasible)

Required behavior:

1. Never require unrestricted filesystem APIs.
2. Use security-scoped URLs for user-picked files and release access promptly.
3. Keep all extracted/transcoded temporary files under app-owned `tmp`/cache directories.
4. Expose pluggable storage/cache protocols so hosts can route data to app group containers.
5. Do not execute external binaries or shell commands.
6. Treat network as optional capability behind host-provided loader.
7. Support offline-only mode end-to-end.

Required API:

```swift
public struct OpenOptions: Sendable {
    public var allowsNetwork: Bool
    public var tempDirectory: URL?
    public var fileAccess: FileAccessPolicy
}

public protocol FileAccessPolicy: Sendable {
    func withReadAccess<T>(to url: URL, _ body: (URL) throws -> T) rethrows -> T
}
```

Implementation note:

- Provide a default `SandboxFileAccessPolicy` that wraps security-scoped resource access on Apple platforms.

## 18. Assets (Images, Fonts, Media)

Rendering must support:

- Inline and block images from EPUB manifest, FB2 binaries, MOBI resources, and AZW3/KF8 resources.
- Font assets (`@font-face`) loaded from local book assets only by default.
- Audio/video tags only when host app opts in.
- PDF embedded images via PDF adapter.

Loading model:

1. Normalize all asset references to canonical IDs.
2. Resolve IDs through an internal resource map.
3. Serve content through a sandbox-safe local scheme (`bookkit://asset/<id>`).
4. Cache decoded image data in memory + disk cache with size limits.
5. Emit diagnostics for missing/broken assets and continue rendering.

Security rules:

- Deny `file://` references outside allowed sandbox roots.
- Deny remote `http(s)` asset fetch unless `OpenOptions.allowsNetwork == true`.
- Enforce MIME/type sniff checks before decode.

## 19. Link Handling

The renderer must classify links before navigation:

- Internal anchor link (`#note-1`) -> jump within current chapter.
- Internal spine link (`chapter2.xhtml#p4`) -> open chapter and jump.
- External link (`https://...`) -> blocked by default; delegated to host policy.
- Unsupported scheme (`javascript:`, custom unknown) -> blocked.

Host control API:

```swift
public enum LinkAction: Sendable {
    case follow
    case openExternally
    case block
}

public protocol LinkPolicy: Sendable {
    func action(for url: URL, context: LinkContext) async -> LinkAction
}
```

Default policy:

- Follow internal links.
- Block external links unless host explicitly allows.

## 20. Web Bridge and Paging Control (Reflow Formats)

`WKWebView` bridge is required for reliable pagination and reading position sync.

Bridge constraints:

- Book content JavaScript disabled by default.
- Bridge script runs in an isolated content world.
- No arbitrary script execution from book content.
- Message channel must accept only validated bridge payloads.

PDF paging:

- PDF mode does not use JS bridge pagination.
- `PDFPageAdapter` exposes page count and page index navigation.
- `Reader` normalizes PDF page index into `Position`.

Native -> Web commands:

- `setContent(html, css, viewport)`
- `goToAnchor(id)`
- `goToProgression(value)`
- `setTheme(theme)`
- `setTypography(settings)`
- `measurePages()`

Web -> Native events:

- `ready`
- `paginationChanged(pageCount, chapterProgressMap)`
- `positionChanged(spineIndex, progression, cfi?, anchor?)`
- `linkTapped(url, kind)`
- `selectionChanged(range, text)`
- `contentHeightChanged(value)`

Paging model:

1. Layout content to viewport width/height.
2. Measure page breaks in JS using stable DOM markers.
3. Return page map to `Reader`.
4. `Reader` exposes APIs:

```swift
public actor Reader {
    public var position: Position { get async }
    public func go(to position: Position) async throws
    public func nextPage() async throws
    public func previousPage() async throws
}
```

Position accuracy targets:

- Progress updates debounced and stable during scroll/page animation.
- Re-open should restore within +/- 1 screenful equivalent of previous position.
- PDF mode restore should return to the same page index.

## 21. MVP Exit Criteria (v1.0)

`BookKit v1.0` is complete when all are true:

1. EPUB, FB2, MOBI, AZW3/KF8 (unencrypted), and PDF open successfully for the golden corpus.
2. Images/fonts render correctly in at least 95% of corpus chapters.
3. Internal links and footnotes work across chapters.
4. `Reader.go`, `nextPage`, and `previousPage` are stable under rotation/resize.
5. Position restore succeeds after app restart within target tolerance.
6. Sandbox tests pass for iOS and macOS App Sandbox flows.
7. External network access remains blocked by default.
8. PDF page navigation is stable and deterministic.
9. Open corpus verification passes with fixed checksums.

## 22. Locked Decisions

These are frozen for v1.0:

1. Renderer foundation: `WKWebView` for reflow formats + `PDFPageAdapter` for PDF mode.
2. Public naming: `Book*` and `Reader`, no `Unified*`.
3. Security posture: sandbox-first and offline-first by default.
4. License target: MIT.
