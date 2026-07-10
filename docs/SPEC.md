# BookKit v1 specification

Date: 2026-07-10

This document defines the v1 product contract. It is intentionally narrower than
the universe of EPUB, Kindle, FB2, and PDF behavior. See
[`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) for the current evidence
and remaining compatibility work.

## Objective

BookKit provides one native Swift API for:

- opening supported ebook sources inside Apple app sandboxes;
- normalizing format-specific content into one `Book` model;
- rendering reflowable publications and PDF pages;
- navigating with stable positions, TOC entries, page movement, and history;
- exposing live reader events to host applications;
- persisting reading position, preferences, and bookmarks;
- extending reflow rendering with trusted host code without trusting publication
  JavaScript.

## Supported product path

| Area | v1 path |
| --- | --- |
| EPUB | Reflowable EPUB 2/3 with OPF spine, EPUB 3 nav or EPUB 2 NCX, local CSS/assets, TOC, landmarks, and page list |
| FB2 | Structured metadata, semantic body conversion, nested sections/TOC, notes, styles, and embedded images |
| MOBI | Unencrypted MOBI 6 with uncompressed or PalmDOC text, EXTH metadata, file-position links, guide/TOC recovery, and images |
| AZW3/KF8 | Unencrypted PalmDOC/FDST content and style flows, sections, metadata, and embedded images |
| PDF | PDFKit-backed page/text ingestion, metadata, outline TOC, page list, and native page presentation where available |
| Reflow UI | `WKWebView` through `WebViewReflowBridge` and SwiftUI `BookView` |
| PDF UI | `PDFPageAdapter` plus SwiftUI `PDFBookView` on iOS, macOS, and visionOS |

Supported platforms:

- iOS 16+
- macOS 13+
- tvOS 16+
- visionOS 1+
- Swift tools 6.2+

## Non-goals

The following are outside the v1 contract:

- DRM decryption, including Kindle, Adobe, or LCP DRM;
- EPUB fixed-layout rendition and media overlays;
- executing scripts supplied by a publication;
- canonical EPUB CFI generation;
- HUFF/CDIC decompression and complete proprietary KF8 SKEL/FRAG/INDX recovery;
- OCR for scanned PDFs;
- ebook authoring or export;
- guaranteed rendering parity for every vendor-specific document;
- a complete reader application shell owned by the package.

## Design invariants

1. `Book` is the format-independent model.
2. Parser-specific details do not leak into renderer control flow.
3. Disk and network capabilities are explicit through `OpenOptions`.
4. Network access and publication JavaScript are disabled by default.
5. WebKit operations and navigator coordination are main-actor isolated.
6. Mutable reader state is actor-owned and persistable through a protocol.
7. Positions are deterministic and serializable across app launches.
8. Every event subscriber receives an independent stream.
9. Internal links use native navigation; external links use host policy.
10. Unsupported format behavior is documented rather than silently advertised as
    full compatibility.

## Source contract

```swift
public enum BookSource: Sendable {
    case url(URL)
    case data(Data, fileName: String?)
    case stream(fileName: String?, provider: @Sendable () throws -> Data)
}
```

The URL path must work with app-container and security-scoped file-picker URLs.
The default `SandboxFileAccessPolicy` starts and stops security-scoped access for
the duration of the read.

The provider source is deferred but not incrementally parsed. Whole-source `Data`
materialization is an explicit v1 limitation.

## Resource limits

`OpenOptions` must expose:

- network opt-in;
- file-access policy;
- source byte limit;
- individual resource byte limit;
- total uncompressed EPUB byte limit;
- optional app-owned temporary directory.

Invalid or oversized inputs fail with `BookError`; they must not trigger
unbounded extraction or implicit network access.

## Normalized model

`Book` contains:

- stable `id`, detected `format`, and source `version`;
- normalized `Metadata`;
- ordered `[Chapter]` reading order;
- local `[Asset]` resources;
- hierarchical TOC, landmarks, and page list;
- namespaced raw extensions;
- non-fatal parser diagnostics.

`TOCNode` is hierarchical and has a stable ID, title, href, roles, and children.
Paths and fragments are resolved against the normalized reading order.

## Position and navigation contract

`Position` is the persisted location:

- spine/page index;
- section progression from 0 through 1;
- optional anchor;
- optional CFI supplied by an integration;
- optional text context.

`Locator` adds section href and total-publication progression for navigation and
presentation.

The `Navigator` surface must support:

- current locator;
- locator and TOC navigation;
- back/forward jump history;
- scroll/paginated preference;
- reader preferences and accessibility settings;
- typed bridge commands.

`ContentRenderer` additionally supports measured next/previous page movement,
bookmarks, decorations, search-result navigation, and link routing.

## Event contract

`NavigatorEvent` includes:

- readiness;
- locator and pagination changes;
- selection and content-height changes;
- history, reading-mode, preference, and accessibility changes;
- link decisions;
- decoration taps;
- typed custom bridge messages;
- reader errors.

Events are broadcast through fresh buffered `AsyncStream` values. A slow or
cancelled consumer must not take ownership of events intended for another
consumer.

Passive WebKit position reporting is coalesced to animation frames and duplicate
progression/anchor pairs are suppressed. Explicit navigation still reports its
requested position deterministically.

## Persistence contract

`ReaderStateStore` loads and saves a `ReaderSnapshot` keyed by deterministic book
ID. A snapshot contains:

- position;
- bookmarks;
- reader preferences;
- update timestamp.

BookKit supplies in-memory and file-backed stores. Hosts may implement database,
app-group, or cloud storage through the same protocol.

## Reflow rendering contract

`ReflowBridge` separates navigation/layout control from WebKit. The built-in
bridge must:

- wait until its bootstrap document is ready before executing commands;
- sanitize publication HTML and CSS;
- render sections into a stable document;
- apply theme, typography, reading mode, decorations, and accessibility state;
- measure real WebKit page geometry;
- report validated typed events;
- intercept anchor clicks before WebKit navigation;
- keep page-world publication code outside the host bridge world.

`BookView` is only a presentation adapter for the bridge's `WKWebView`.

## Host extension contract

Trusted `ReflowScriptPlugin` code may:

- register unique async command names;
- return JSON-shaped values to Swift;
- post typed custom events;
- observe documented content, position, selection, and link lifecycle hooks;
- read or modify the rendered DOM.

The boundary uses recursive `BridgeValue` values. Publication content cannot
register commands or access the BookKit object when the default security policy is
preserved.

## Link contract

Every publication anchor click is classified as internal anchor, internal spine,
external, or unsupported.

- Internal destinations follow native `ContentRenderer` navigation.
- External destinations are blocked by default.
- A host `LinkPolicy` may return `.openExternally` or `.block`.
- The host, not BookKit, performs the system URL-opening action.
- `javascript:`, `file:`, and unknown schemes remain blocked by default.

## Accessibility contract

The host supplies `ReaderAccessibilitySettings`. BookKit must support:

- VoiceOver-aware effective reading mode;
- preserving the user's saved reading-mode preference;
- reduced-motion DOM behavior;
- optional polite live position announcements;
- semantic publication markup where the source/parser provides it.

The library does not query global accessibility state. The reference example
shows platform observation for macOS and UIKit platforms.

## Security contract

Default behavior must include:

- non-persistent WebKit data storage;
- publication JavaScript disabled;
- host bridge code isolated from the page world;
- script, inline-handler, embedded-frame/object, form, and meta-refresh removal;
- unsafe URL and CSS resource blocking;
- no remote resource fetch without explicit opt-in;
- EPUB entry normalization and archive limits;
- security-scoped file handling;
- bridge message validation before public event delivery.

A host can override some WebKit configuration defaults. Doing so is an explicit
security-policy change owned by that host.

## Errors and diagnostics

Blocking failures use `BookError` families for unsupported format, I/O, invalid
container, malformed document, missing asset, navigation, and rendering.

Recoverable parser concerns should be represented by `BookDiagnostic` when the
publication can still be opened.

## v1 acceptance criteria

The v1 implementation is acceptable when:

1. every manifest fixture passes checksum verification and opens successfully;
2. stable publication IDs survive reopening;
3. EPUB/FB2/MOBI/AZW3 corpus assertions prove real structure, text, navigation,
   styles, and assets rather than only non-throwing parse;
4. PDF page/index navigation is deterministic;
5. internal anchor, spine, and TOC navigation are integration-tested;
6. live position and custom bridge behavior run against real `WKWebView`;
7. offline/security limits have deterministic unit coverage;
8. state, preferences, and bookmarks round-trip through built-in stores;
9. the package passes `swift test` and a release build;
10. `BookKitExample` compiles for every declared Apple platform and can open
    corpus files through its deterministic demo path;
11. unsupported boundaries remain listed in
    [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md).

## Naming rules

- Prefer short domain types: `Book`, `Reader`, `Position`, `Locator`.
- Keep format names on format-specific parsers only.
- Prefer verb entry points such as `Book.open`, `renderer.go`, and
  `renderer.nextPage`.
- Do not add legacy `Ebook*`, `Unified*`, or redundant `BookPublication*` aliases.

## Licensing and references

BookKit is MIT-licensed. Projects under `refs/` are used for architecture and
behavior comparison under their own permissive licenses. Any future adaptation
must preserve required notices and must not mechanically port incompatible code.
