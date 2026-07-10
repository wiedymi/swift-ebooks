# BookKit implementation status

Date: 2026-07-10

This document is the source of truth for implemented behavior. `SPEC.md` is the
architecture target; a checked box here means the behavior is backed by automated tests.

## Reader and navigation

| Area | Status | Notes |
| --- | --- | --- |
| Live location | Implemented | `Locator` carries section, section progression, total progression, anchor, optional CFI, and text context. WebKit scroll events publish updates without host polling. |
| Measured page movement | Implemented | Next/previous use the current WebKit `PageMap`, cross section boundaries, and use page indexes for PDF. |
| TOC activation | Implemented | `go(to: TOCNode)` resolves section-relative paths/fragments and renders the destination. |
| Publication links | Implemented | Anchor and spine links route through native navigation. External links go through the host `LinkPolicy`; WebKit never races the native action. |
| Event delivery | Implemented | Every subscriber receives its own buffered stream. Ready, locator, page map, selection, content height, history, preferences, accessibility, links, decorations, plug-in messages, and errors are exposed. |
| Persistence | Implemented | Stable publication IDs, position, preferences, bookmarks, and jump history behavior are covered. |
| Canonical EPUB CFI generation | Not implemented | CFI remains an optional field accepted from integrations. Anchors plus progression are the built-in position mechanism. |

The EPUB behavior follows the reading-system requirements to expose the navigation
document TOC and relocate when an internal hyperlink is activated:
[EPUB 3.3 Reading Systems](https://www.w3.org/TR/epub-rs-33/).

## Format support

| Format | Implemented | Known boundary |
| --- | --- | --- |
| EPUB 2/3 | ZIP/container/OPF, ordered spine, metadata, EPUB 3 nav, EPUB 2 NCX fallback, hierarchical TOC, landmarks, page list, linked/inline CSS, and embedded resources. | Fixed-layout rendition, media overlays, scripted EPUB, fallback chains, and full CFI generation are not implemented. Reflowable publications are the supported production path. |
| FB2 | Structured title/author/language/publisher/date, semantic HTML conversion, nested sections/TOC, notes landmarks, stylesheets, and base64 binaries. | Rare extension elements are rendered as their child content. Binary media beyond images is retained but not given a specialized player. |
| MOBI 6 | Palm container validation, uncompressed/PalmDOC text, trailing-data handling, EXTH metadata, file-position anchors/links, guide/TOC recovery, and image records. | HUFF/CDIC compression and every vendor-specific INDX/NCX variant are not implemented. |
| AZW3/KF8 | PalmDOC content, EXTH metadata, FDST content/style flows, multi-document chapters, CSS, and embedded images. | Full SKEL/FRAG reconstruction and exact proprietary `kindle:pos`/NCX resolution remain best-effort. DRM is unsupported. |
| PDF | PDFKit pages/text, metadata, outline TOC, page list, stable IDs, page navigation, and native SwiftUI PDF view. | PDF annotations/link activation are not projected into `NavigatorEvent`. Scanned pages do not gain OCR. |

## JavaScript extension boundary

Implemented:

- typed recursive `BridgeValue` payloads
- app-to-plug-in async commands (`registerCommand` / `callBridgeCommand`)
- plug-in-to-app events (`BookKit.post` / `NavigatorEvent.bridgeMessage`)
- lifecycle hooks: `contentWillChange`, `contentDidChange`, `positionChanged`,
  `selectionChanged`, and `linkTapped`
- multiple independent event subscribers
- host `WKWebViewConfiguration` customization
- `WKContentWorld.defaultClient` isolation while sharing the publication DOM

The isolation design uses WebKit content worlds as documented by Apple:
[`WKContentWorld`](https://developer.apple.com/documentation/webkit/wkcontentworld).

## Accessibility

Implemented:

- host-controlled VoiceOver state
- optional forced scroll mode while VoiceOver is active without losing the saved preference
- reduced-motion DOM state and scroll behavior
- throttled five-percent/anchor position announcements through a polite live region
- semantic publication markup preservation
- automatic VoiceOver and reduced-motion observation in the example app

The library does not query global accessibility state itself; host apps own that policy
and pass `ReaderAccessibilitySettings`.

## Security and resource policy

Implemented:

- publication JavaScript disabled
- BookKit/app JavaScript isolated from the page world
- script/inline-handler/embedded-frame/form/meta-refresh sanitization
- implicit remote resources blocked unless `allowsNetwork` is explicitly enabled
- external anchors preserved for native `LinkPolicy` decisions
- non-persistent WebKit data store
- source, per-resource, and total uncompressed EPUB limits
- EPUB entry/path normalization and security-scoped file policy
- asynchronous URL loading and parsing off the main actor

## Remaining roadmap

Highest-value remaining work:

1. full EPUB fixed-layout and media-overlay renderers;
2. canonical EPUB CFI generation and text-quote re-anchoring;
3. KF8 SKEL/FRAG/INDX reconstruction, exact `kindle:pos`, and HUFF/CDIC;
4. truly incremental source/archive parsing instead of whole-source `Data` ingestion;
5. PDF annotation and link events;
6. larger adversarial and accessibility fixture corpora.
