# BookKit implementation status

Date: 2026-07-10

This is the source of truth for implemented behavior. An `Implemented` entry is
backed by automated tests; it is not a claim that every producer-specific file is
compatible.

## Reader and navigation

| Area | Status | Evidence-backed behavior |
| --- | --- | --- |
| Normalized publication model | Implemented | Reflowable, fixed-page, PDF, and timed-audio publications share `Book`, `Chapter`, `Asset`, `TOCNode`, `Position`, and `Locator`. |
| Live position | Implemented | Reflow scroll events, fixed-page visibility, PDF page notifications, and audiobook time events can update host UI without polling. Audiobook book progress is duration weighted. |
| Page movement | Implemented | Measured WebKit pages cross sections; PDF/fixed pages use section indexes; audiobook navigation changes tracks. |
| TOC, landmarks, and page lists | Implemented | Hierarchies remain nested. Relative EPUB paths, PDF custom-scheme pages, DjVu targets, and audiobook media fragments resolve to locators. |
| Internal and external links | Implemented | Reflow and fixed-page links route through `ContentRenderer`; external URL annotations in `PDFBookView` are intercepted. `LinkPolicy` decides follow/open/block. |
| Fixed-page customization | Implemented | `FixedPageBookView` exposes fitted geometry, link bounds, accessible hit targets, visibility locators, and an arbitrary host overlay builder. |
| Events | Implemented | Independent buffered streams expose readiness, locators, pagination, selections, content height, history, preferences, accessibility, links, decorations, plug-in messages, and errors. |
| Persistence | Implemented | Stable IDs, positions/timestamps, preferences, bookmarks, and file/in-memory stores are covered. |
| Search | Implemented | In-memory first-match-per-section search over normalized content, including DjVu OCR text. |
| Canonical EPUB CFI generation | Not implemented | CFI values supplied by an integration are retained. Anchors, progression, text context, and timestamps are BookKit's built-in location mechanisms. |

## Format support

| Format | Implemented path | Known boundary |
| --- | --- | --- |
| EPUB 2/3 | ZIP/container/OPF, metadata, ordered spine, EPUB 3 nav, EPUB 2 NCX, nested TOC, landmarks, page list, linked/inline CSS, embedded resources, IDPF-obfuscated fonts, pre-paginated XHTML, and direct image spines. | Media overlays, scripted EPUB, full fallback-chain selection, canonical CFI generation, and every vendor rendition extension are not implemented. |
| FB2 | Structured metadata, semantic HTML conversion, nested sections/TOC, notes landmarks, styles, and base64 binaries. `.fb2.zip` safely accepts exactly one FB2 document. | Rare extension elements fall back to their child content. Specialized non-image binary playback is not provided. |
| MOBI 6 | Palm validation, uncompressed/PalmDOC text, trailing-data handling, EXTH metadata, file-position anchors/links, guide/TOC recovery, and images. | HUFF/CDIC compression and every proprietary INDX/NCX variant are not implemented. |
| AZW3/KF8 | PalmDOC, EXTH metadata, FDST content/style flows, multiple chapters, CSS, and embedded images. | Complete SKEL/FRAG reconstruction and exact proprietary `kindle:pos`/NCX resolution remain best effort. HUFF/CDIC is unsupported. |
| PDF | PDFKit pages/text/metadata, outline TOC, page list, native presentation, live page callbacks, internal PDF actions, and host-routed URL annotations. | Scanned pages do not gain OCR. Encrypted PDFs are always rejected, even when PDFKit could display one without prompting. |
| CBZ | Safe ZIP extraction, natural page order, common ImageIO formats, ComicInfo metadata/bookmarks, cover and double-page detection, LTR/RTL manga progression, spreads, thumbnails, and prefetch. | CBR/RAR is intentionally unsupported. Animated images are presented as page images rather than a comic-specific animation timeline. |
| DjVu | Single and bundled documents, DIRM/INCL shared components, NAVM, ANTa/ANTz, TXTa/TXTz, BZZ/ZP, progressive IW44, JB2/shared dictionaries, regular/striped MMR, JPEG layers, palettes, rotation, raster composition, OCR text, outlines, and map-area links. | Indirect multi-file DjVu, standalone PM44/BM44, native vector annotation rendering, and every obscure extension chunk are not claimed. Page output is JPEG or PNG. |
| TXT | UTF-8/UTF-16 decoding, escaped paragraph conversion, stable ID, and reflow rendering. | It is a convenience single-document adapter; arbitrary legacy encodings and automatic chapter inference are not implemented. |
| HTML | Safe single-document import, heading IDs, nested TOC, and normal native link policy. | Sibling-file packaging and a general website downloader are not provided. Active content is sanitized. |
| Markdown | Headings/nested TOC, paragraphs, lists, links, emphasis, quotes, fenced/inline code, and safe HTML output. | It is a focused reader adapter, not a CommonMark conformance claim or Markdown authoring system. |
| Audiobook | W3C/Readium manifests, root-manifest ZIP packages, standalone MP3/M4A/M4B/AAC, metadata/artwork/chapters, media fragments, AVFoundation playback, rates, persistence, bookmarks, Now Playing, and remote commands. | Protected audio is rejected. Remote manifest tracks require explicit `allowsNetwork` and are rejected on visionOS because protected-content status cannot be verified there; advanced streaming/download management is host-owned. |

## Fixed-page and audiobook surfaces

Implemented fixed-page types:

- `FixedPageAdapter` for page/position/asset/spread mapping;
- `FixedPageBookView` for presentation, accessible links, live visibility, and
  host overlays;
- `FixedPageOverlayContext` for source-pixel-to-view geometry;
- `ImagePageStore` for bounded PNG thumbnails and concurrent neighboring-page
  prefetch.

Implemented audiobook types:

- `AudiobookTimeline` for track, timestamp, and total-duration mapping;
- `AudiobookPlayer` for state, events, seeking, rates, bookmarks, and remote
  commands;
- `AVFoundationAudiobookEngine` as the built-in playback engine;
- `AudioResourceStore` for packaged, file, and explicitly allowed network audio.

## JavaScript extension boundary

Implemented:

- recursive `BridgeValue` payloads;
- app-to-plug-in async commands;
- plug-in-to-app typed events;
- content, position, selection, and link lifecycle hooks;
- multiple independent subscribers;
- host `WKWebViewConfiguration` customization;
- `WKContentWorld.defaultClient` isolation while sharing the rendered DOM.

Publication JavaScript is not a plug-in and remains disabled/sanitized by default.

## Accessibility

Implemented:

- host-controlled VoiceOver and reduced-motion settings;
- optional scroll mode while VoiceOver is active without overwriting the saved
  preference;
- polite reflow position announcements;
- preserved semantic markup;
- fixed-page image labels, page values, and named link buttons with minimum hit
  targets;
- native PDFKit and audiobook control accessibility in the example app.

BookKit does not query global accessibility state. The reference app demonstrates
platform observation and passes policy into the library.

## DRM and protection policy

BookKit is intentionally DRM-free only. It does not expose passwords, keys,
licenses, or decryption callbacks.

| Protection | Behavior |
| --- | --- |
| ZIP traditional/strong encryption or decryption headers | Reject before extraction |
| EPUB `encryption.xml` | Allow only standard IDPF font obfuscation; reject all other algorithms |
| Kindle PalmDOC encryption | Reject before content decoding |
| PDF encryption | Reject when `PDFDocument.isEncrypted` is true |
| Audiobook encrypted properties/manifests | Reject during manifest validation |
| AVFoundation protected content | Reject during inspection and again before playback |
| Secure DjVu (`SDJV`) | Reject before DjVu parsing |

The native frameworks are decoders/renderers after these checks; BookKit never
uses platform behavior to bypass protection.

## Security and resource policy

Implemented:

- publication JavaScript disabled and host bridge code isolated;
- script, inline-handler, frame/object, form, and meta-refresh sanitization;
- remote resources blocked unless explicitly enabled;
- non-persistent WebKit storage;
- source, individual-resource, archive-entry-count, and aggregate-uncompressed
  limits;
- encrypted ZIP and unsafe archive-path rejection;
- security-scoped file access;
- bounded DjVu chunks, decoder records, dimensions, and output buffers;
- temporary audiobook cleanup.

## Verification evidence

- deterministic unit tests for every format and protection path;
- live offscreen `WKWebView` tests for isolation, accessibility, links, commands,
  hooks, and position reporting;
- AVFoundation inspection/playback tests with a real unprotected audio fixture;
- DjVu arithmetic, BZZ, IW44, JB2, MMR, composition, shared-component, text,
  outline, and annotation fixtures;
- checksum-pinned EPUB, FB2, MOBI, AZW3, and PDF corpus books;
- debug and release SwiftPM builds plus declared-platform build commands;
- deterministic `BookKitExample --demo <path>` readiness markers.

## Remaining compatibility work

1. canonical EPUB CFI generation, text-quote re-anchoring, and EPUB media overlays;
2. KF8 SKEL/FRAG/INDX breadth and HUFF/CDIC;
3. indirect multi-file DjVu and broader unusual-chunk corpus coverage;
4. incremental source/archive parsing rather than whole-source `Data` ingestion;
5. OCR for image-only PDF/CBZ pages as an optional host service;
6. larger adversarial, fuzz, visual-regression, and automated accessibility corpora.
