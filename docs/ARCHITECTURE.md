# BookKit architecture

BookKit keeps format-specific parsing behind a normalized publication model. The
host owns application chrome, state presentation, external URL opening, and
optional product features such as narration or annotations.

## Data flow

```text
BookSource + OpenOptions
        |
        v
FormatSniffer -> ParserRegistry
        |
        +-- EPUB / FB2 / MOBI / AZW3 / document adapters
        +-- PDF
        +-- CBZ / fixed-image EPUB / DjVu
        +-- audiobook manifests/packages/files
        |
        v
Book + Metadata + Chapter + Asset + TOCNode + Presentation
        |
        v
BookReader + one shared ReaderStateActor
        |
        +-- reflow/XHTML fixed -> ContentRenderer -> ReflowLayout -> WebViewReflow
        +-- PDF                -> ContentRenderer -> PDFPageAdapter + PDFBookView
        +-- bitmap fixed       -> ContentRenderer -> FixedPageAdapter + FixedPageBookView
        +-- audiobook          -> AudiobookTimeline + AudiobookPlayer -> playback engine
        |
        v
BookReaderView
```

`BookReader` is the public session boundary. It owns engine selection, navigation,
persistence, observable state, link policy, events, and lifecycle. `BookReaderView`
selects the native presentation internally. `ContentRenderer` and
`AudiobookPlayer` remain focused engines behind the session.

## Source and parser layer

`BookSource` supports a URL, existing `Data`, or deferred provider. `OpenOptions`
owns file access, network policy, temporary storage, and resource/archive limits.

`Book.open`:

1. reads through `FileAccessPolicy`;
2. enforces `maxSourceBytes`;
3. detects extension/signature;
4. selects `BookParser` from `ParserRegistry`;
5. validates container/protection rules;
6. produces the common model;
7. maps failures into `BookError`.

`ParserRegistry.default` contains EPUB, FB2, MOBI, AZW3, PDF, CBZ, document,
audiobook, and DjVu parsers.

The current pipeline materializes the full source. `SafeZIPArchive` centralizes
encrypted-entry, traversal, entry-count, per-entry, and total-expansion checks for
CBZ, FB2 ZIP, and packaged audiobooks. EPUB performs equivalent package-specific
checks before entry reads.

## Protection gate

Protection checks are parser inputs, not renderer options:

```text
source
  -> encrypted-container/header/manifest inspection
  -> reject with BookError.protectedContent
  -> only DRM-free content reaches normal decode/render/playback
```

PDFKit, AVFoundation, WebKit, and ImageIO are never used as decryption services.
Audio receives a second AVFoundation protection check immediately before
playback. EPUB's standard IDPF font obfuscation is reversed as a publication
resource transform; other EPUB encryption is rejected.

## Normalized publication model

Every parser produces:

- `Metadata`;
- ordered `Chapter` values;
- `Asset` resources;
- hierarchical TOC, landmarks, and page list;
- stable ID and format/version;
- `BookPresentation` describing reflowable, fixed, or audiobook layout;
- typed page/audio details where relevant;
- raw namespaced metadata and recoverable diagnostics.

Fixed-page link coordinates are normalized to source pixels with a top-left
origin. DjVu's bottom-left map-area coordinates are converted during parsing so
the view layer stays format independent.

## Reader state ownership

`ReaderStateActor` is responsible for position, preferences, bookmarks, and
`ReaderStateStore` persistence. It owns no platform view. Each `BookReader`
creates exactly one state actor and injects it into both navigation and playback,
so an audiobook never has competing persistence owners.

`BookReader` and `ContentRenderer` are `@MainActor`. `ContentRenderer` owns:

- a normalized `Book` and one `ReaderStateActor`;
- the active reflow, PDF, or fixed-page adapter;
- jump history;
- decorations/accessibility policy;
- link routing and visual navigator events.

`BookReader` maps renderer and player events into published state and one
`BookReaderEvent` stream. This keeps persistence mutable state off the UI actor
while framework-facing coordination stays on the correct actor.

## Reflow and XHTML fixed layout

`ReflowLayout` translates renderer operations into `ReflowBridge` commands and
maps bridge events back to the current reading-order index.

`WebViewReflowBridge`:

- owns a non-persistent `WKWebView`;
- waits for bootstrap readiness;
- disables page-world publication JavaScript;
- installs BookKit and host plug-ins in an isolated client content world;
- validates every inbound message;
- applies theme, typography, layout, decoration, and accessibility state;
- measures real layout and coalesces passive positions;
- intercepts links before WebKit navigation.

Pre-paginated XHTML chapters use the same engine with a scaled fixed-page wrapper.
Direct image spines use the bitmap path instead.

## Fixed-page engine

`FixedPageAdapter` maps pages, positions, assets, covers, sides, and spreads. It
uses the publication reading progression to return LTR or RTL visual order.

`FixedPageBookView` aspect-fits one page/spread and layers:

1. decoded image;
2. transparent accessible link buttons;
3. an arbitrary host overlay.

`FixedPageOverlayContext` converts page-source rectangles into fitted SwiftUI
coordinates. This lets apps add voice-over focus, word/region highlighting,
annotations, or live measurement UI without changing BookKit's renderer.

`ImagePageStore` is an actor with a byte-bounded LRU-like thumbnail cache. It
creates ImageIO thumbnails concurrently around a page but caps requested radius.

## DjVu decoder

The DjVu path is implemented inside BookKit:

```text
IFF FORM/DIRM/INCL
  -> BZZ + ZP arithmetic streams
  -> IW44 background/foreground
  -> JB2 or striped/regular MMR mask
  -> FGbz palette / JPEG layers
  -> page raster + rotation
  -> JPEG passthrough or PNG asset
```

NAVM becomes nested `TOCNode` values. TXTa/TXTz supplies searchable OCR text.
ANTa/ANTz map areas become `PageLink` values, including relative page targets and
rect/oval/text/poly/line bounds. Decoder dimensions, output bytes, records,
component count, and inclusion depth are bounded by `OpenOptions` or fixed safety
caps.

The code does not depend on DjVuLibre.

## PDF

`PDFParser` rejects encrypted documents, then creates one normalized section per
page, outline TOC nodes, page-list entries, and a retained `pdf-document` asset.

`PDFPageAdapter` maps pages to positions. `PDFBookView` presents PDFKit, reports
page-change notifications, preserves native internal page actions, and implements
the URL-link delegate so PDFKit does not implicitly open external URLs. The host
routes those URLs through its policy.

## Audiobooks

`AudiobookTimeline` maps track indexes, clip bounds, timestamps, local progress,
and duration-weighted total progress.

`AudiobookPlayer` owns audio-specific behavior:

- `AudioResourceStore` materialization/network policy;
- an injectable `AudiobookPlaybackEngine`;
- playback/time/track events;
- rate, seek, next/previous behavior;
- bookmarks;
- Now Playing and remote commands;
- cleanup.

The enclosing `BookReader` supplies the same state actor used by navigation,
projects playback snapshots into observable session state, and exposes unified
navigation and bookmark commands.

The default engine is `AVFoundationAudiobookEngine`. Tests inject a fake engine
for deterministic state transitions and also exercise AVFoundation with real
unprotected audio.

## Navigation and events

Reflow state flows upward:

```text
WebKit scroll/command
  -> ReflowBridgeEvent
  -> ReflowLayoutEvent with active section
  -> ContentRenderer updates ReaderStateActor
  -> NavigatorEvent
  -> every host subscriber
```

`BookReaderView` consumes fixed/PDF visibility and page callbacks and synchronizes
them with `ContentRenderer`; these callbacks do not escape into ordinary host
code. Audiobook events are similarly projected through `BookReader`.

Navigation href resolution supports relative publication paths, exact internal
custom-scheme URLs, anchors, DjVu directory targets, and audiobook media
fragments. External URLs are policy decisions, not implicit navigation.

## Persistence

`ReaderStateStore` implementations:

- `InMemoryReaderStateStore` for tests/temporary sessions;
- `FileReaderStateStore` for app-owned JSON.

Snapshots contain position/timestamp, preferences, bookmarks, and update time.
Hosts can provide database, app-group, or cloud persistence without changing the
navigator.

## Extension points

| Need | Extension point |
| --- | --- |
| Complete reading session | `BookReader` |
| Default presentation for every format | `BookReaderView` |
| Parser selection | `ParserRegistry` / `BookParser` |
| App-group/custom file access | `FileAccessPolicy` |
| Database/cloud state | `ReaderStateStore` |
| External URL decisions | `LinkPolicy` |
| Trusted DOM behavior | `ReflowScriptPlugin` |
| Fixed-page UI/voice-over/annotations | `FixedPageBookView` overlay builder |

## Invariants

- Parser output is independent of a particular UI.
- Protected content never reaches ordinary rendering/playback.
- Network and publication code execution require explicit host decisions.
- Framework mutations and navigator coordination stay main-actor isolated.
- Cross-format positions remain serializable and deterministic.
- Host customization composes around stable model/geometry/event boundaries.
