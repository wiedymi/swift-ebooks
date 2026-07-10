# BookKit architecture

BookKit exposes one Swift package product and keeps format-specific parsing behind
a normalized publication model. The host chooses presentation, persistence, link
policy, and optional DOM extensions.

## Data flow

```text
BookSource + OpenOptions
        |
        v
FormatSniffer -> ParserRegistry -> EPUB / FB2 / MOBI / AZW3 / PDF parser
        |                              |
        +------------------------------+
                       |
                       v
        Book + Chapter + Asset + TOCNode
                       |
                       v
             Normalize / sanitize / style
                       |
             +---------+---------+
             |                   |
             v                   v
      ContentRenderer      SearchIndex / ResourceLoader
             |
       +-----+-----+
       |           |
       v           v
 ReflowLayout   PDFPageAdapter
       |           |
       v           v
WebViewReflow  PDFBookView / host view
       |
       v
    BookView
```

## Source and parsing layer

`BookSource` supports a URL, existing `Data`, or a deferred data provider.
`OpenOptions` owns file access, network policy, and size limits.

`Book.open` performs these steps:

1. read the source through the configured `FileAccessPolicy`;
2. enforce `maxSourceBytes`;
3. detect the format from extension and signature;
4. select a parser from `ParserRegistry`;
5. parse into the common `Book` model;
6. map parser failures into `BookError`.

`ParserRegistry.default` contains EPUB, FB2, MOBI, AZW3, and PDF parsers. A host
can construct another registry to replace a parser or add a format already
represented by `BookFormat`.

The current pipeline materializes the complete source as `Data`. EPUB also tracks
the total uncompressed archive size before extracting entries. Truly incremental
archive parsing remains future work.

## Normalized publication model

Every parser produces:

- `Metadata` for title, authors, language, identifiers, publisher, and date;
- ordered `Chapter` values with normalized HTML-like content;
- `Asset` values for styles, images, fonts, and retained source data;
- hierarchical `TOCNode` arrays for TOC, landmarks, and page list;
- stable publication ID and parser-specific `rawExtensions`;
- non-fatal `BookDiagnostic` entries where available.

The renderer does not reach back into format-specific parser state. Format
differences must be represented in this model or kept as namespaced raw metadata.

## Normalization and resources

`Normalize` applies deterministic content sanitization and network policy before
rendering. `ResolveStyles` combines host theme/typography with base CSS.

For reflow rendering, `ContentRenderer` maps known local assets into data URLs and
rewrites normalized chapter references. `ResourceLoader` is also public for hosts
that need asset data by ID or `bookkit://asset/<id>` URL.

The default policy removes or blocks active and implicit content, including:

- scripts and inline event handlers;
- embedded frames/objects and form submission;
- meta refresh;
- unsafe URL schemes;
- remote CSS imports and resource URLs while network access is disabled.

External anchor hrefs are retained so native `LinkPolicy` can make the decision.

## Reader state ownership

`Reader` is an actor responsible for position, preferences, bookmarks, and state
persistence. It does not own a platform view.

`ContentRenderer` is `@MainActor` and is the public navigation coordinator. It
owns:

- the normalized `Book`;
- one `Reader` actor;
- either `ReflowLayout` or `PDFPageAdapter`;
- jump-history stacks;
- decorations and accessibility policy;
- link routing and the public event hub.

This separation keeps mutable persistence state off the UI actor while ensuring
that WebKit and view-facing state are never accessed from the wrong actor.

## Reflow rendering

`ReflowLayout` translates renderer operations into `ReflowBridge` commands and
maps bridge events back to the active spine index.

`WebViewReflowBridge` is the built-in implementation:

- owns a non-persistent `WKWebView`;
- waits for its bootstrap document before accepting commands;
- installs the BookKit runtime at document start;
- disables publication-page JavaScript by default;
- validates every message before exposing an event;
- measures pagination from actual WebKit layout;
- coalesces passive position reporting to one animation frame;
- supports trusted host plug-ins in an isolated content world.

`BookView` only embeds that web view in SwiftUI. It deliberately does not own
navigation bars, TOC UI, gestures, settings, or app state.

## PDF rendering

`PDFParser` uses PDFKit to create one normalized section per page, outline-derived
TOC nodes, page-list entries, and the retained original document asset
`pdf-document`.

`PDFPageAdapter` maps page indexes to `Position`. `ContentRenderer` uses the same
navigator surface for PDF, while `PDFBookView` presents the document natively on
iOS, macOS, and visionOS.

PDF does not use `ReflowBridge`, DOM decorations, or JavaScript plug-ins.

## Navigation and events

Position changes flow upward rather than being polled:

```text
WebKit scroll/command
    -> ReflowBridgeEvent
    -> ReflowLayoutEvent (active spine index applied)
    -> NavigatorEvent
    -> host AsyncStream consumer(s)
```

Each event property access creates a separate buffered stream. `EventHub` fans out
to every active subscriber and finishes streams when the owner is released.

Internal link clicks are intercepted inside WebKit, classified in native code,
resolved against the current chapter, and executed by `ContentRenderer`. External
links never navigate WebKit directly; the host policy decides their action.

## Persistence

`ReaderStateStore` is the persistence boundary. Built-in implementations are:

- `InMemoryReaderStateStore` for tests and temporary sessions;
- `FileReaderStateStore` for app-owned JSON files.

Snapshots are keyed by a deterministic publication ID and contain position,
preferences, bookmarks, and update time. A database or cloud-backed host can
implement the same protocol without changing the reader.

## Extension points

| Need | Extension point |
| --- | --- |
| Different parser selection | `ParserRegistry` / `BookParser` |
| App-group or custom file access | `FileAccessPolicy` |
| Database/cloud reader state | `ReaderStateStore` |
| External-link decisions | `LinkPolicy` |
| Another reflow engine | `ReflowBridge` |
| DOM-level trusted features | `ReflowScriptPlugin` |
| App-specific WebKit setup | `WebViewReflowConfiguration` |

## Invariants

- Parser output is platform-view independent.
- The host explicitly opts into network access.
- Publication JavaScript is not the same trust domain as host plug-ins.
- WebKit mutations and navigator coordination stay on the main actor.
- Cross-format positions remain serializable and deterministic.
- Unsupported proprietary behavior is reported as a boundary, not silently
  advertised as full compatibility.
