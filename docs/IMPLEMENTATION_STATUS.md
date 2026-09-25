# BookKit implementation status

These paths have automated tests. Producer-specific files can still be incompatible.
See [contracts](SPEC.md), [architecture](ARCHITECTURE.md), and
[validation](TEST_COVERAGE.md) for shared behavior and checks.

## Reader and navigation

| Area | Status | Evidence-backed behavior |
| --- | --- | --- |
| Unified reader session | Implemented | `BookReader` selects the engine, restores one shared state owner, exposes observable navigation/playback state, and owns lifecycle for every supported format. |
| Unified SwiftUI surface | Implemented | `BookReaderView` presents reflow, fixed-image, PDF, and audiobook publications without host format branching or bridge/view callback wiring. |
| Normalized publication model | Implemented | Reflowable, fixed-page, PDF, and timed-audio publications share `Book`, `Chapter`, `Asset`, `TOCNode`, `Position`, and `Locator`. |
| Live position | Implemented | Reflow scroll events, fixed-page visibility, PDF page notifications, and audiobook time events can update host UI without polling. Audiobook book progress is duration weighted. |
| Page movement | Implemented | Measured WebKit pages cross sections; PDF/fixed pages use section indexes; audiobook navigation changes tracks. |
| TOC, landmarks, and page lists | Implemented | Hierarchies remain nested. Relative EPUB paths, PDF custom-scheme pages, DjVu targets, and audiobook media fragments resolve to locators. |
| Internal and external links | Implemented | `BookReaderView` routes reflow, fixed-page, and PDF links through the session. `LinkPolicy` decides follow/open/block. |
| Fixed-page customization | Implemented | `FixedPageBookView` exposes fitted geometry, link bounds, accessible hit targets, visibility locators, and an arbitrary host overlay builder. |
| Events | Implemented | `BookReaderEvent` independently broadcasts navigation, presentation, links, decorations, plug-ins, playback, and errors while published properties expose current state. |
| Persistence | Implemented | Stable IDs, positions/timestamps, preferences, bookmarks, and file/in-memory stores are covered. |
| Search | Implemented | All non-overlapping text matches up to a host limit, Unicode-aware matching options, text previews, cancellation, and precise locations. |
| Text highlights | Implemented | Cross-element reflow ranges, PDF line ranges and multi-page selections, quote/context recovery, independent style groups, selection controls, and host-owned storage. |
| Speech and dubbing | Implemented | Optional system speech, pause/resume/stop, bounded sentence text, word locations, custom engine injection, and app-driven cues. |
| Canonical EPUB CFI | Not implemented | CFI values supplied by an integration are retained. Anchors, progression, text context, and timestamps are BookKit's built-in location mechanisms. |

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
| Audiobook | W3C/Readium manifests, root-manifest ZIP packages, standalone MP3/M4A/M4B/AAC, metadata/artwork/chapters, media fragments, AVFoundation playback, rates, persistence, bookmarks, Now Playing, and remote commands. | Protected audio is rejected. Local manifest tracks must stay inside the manifest directory and fit the configured resource and total size limits. Remote manifest tracks require explicit `allowsNetwork` and are rejected on visionOS because protected-content status cannot be verified there; advanced streaming/download management is host-owned. |

## Remaining compatibility work

1. canonical EPUB CFI and EPUB media overlays;
2. KF8 SKEL/FRAG/INDX breadth and HUFF/CDIC;
3. indirect multi-file DjVu and broader unusual-chunk corpus coverage;
4. incremental source/archive parsing rather than whole-source `Data` ingestion;
5. OCR for image-only PDF/CBZ pages as an optional host service;
6. larger adversarial, fuzz, visual-regression, and automated accessibility corpora.

Text extraction does not evaluate external CSS. Native PDF text color cannot be
changed by decoration styles. OCR for image-only content and remote voice services
remain app-owned. Automated checks cover system-voice error handling and custom
engine state; audible output, VoiceOver speech, and background audio still need
real-device checks.
