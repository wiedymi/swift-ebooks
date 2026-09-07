# Product contracts

BookKit opens, presents, navigates, and persists DRM-free books on Apple platforms.
See [support limits](IMPLEMENTATION_STATUS.md) for format compatibility and
[Package.swift](../Package.swift) for platform and toolchain requirements.

## Scope

`BookReader` owns the session; `BookReaderView` chooses its presentation.
`Book.open` provides parsing without UI. The host owns app controls, external URL
opening, and optional features such as narration or annotations.

Out of scope: DRM decryption, passwords or keys, CBR/RAR, publication scripts,
website downloads, canonical EPUB CFI creation, complete proprietary Kindle
recovery, automatic OCR, and ebook authoring/export.

## Source and protection

- File access must support app-container and security-scoped URLs.
- Network access is off unless the host enables it. WebKit must enforce this
  after URL decoding, as well as applying markup filtering.
- File and network reads must stop at configured byte limits. Accepted sources
  remain complete `Data`; caller-provided data and provider allocations are
  outside BookKit's control.
- Archives must reject encrypted entries, unsafe paths, excessive entry counts,
  oversized resources, and excessive total expansion before normal extraction.
- Decoder sizes, indices, nesting, and arithmetic must remain within bounds.
- ZIP, Kindle, PDF, audio, and Secure DjVu protection must fail before normal
  decoding or playback. EPUB permits standard IDPF font obfuscation only.
- Protection errors retain kind, scheme, and resource when available. Native
  framework capabilities must not weaken these rules.

## Model and state

`Book` is independent of a UI. It contains stable identity, metadata, ordered
chapters, assets, navigation, presentation details, raw extensions, and diagnostics.
Fixed-page link bounds use source pixels with a top-left origin. Audio chapters
can define clip bounds and duration.

Each reader has one `ReaderStateActor`, shared by navigation and playback.
Framework-facing state runs on `@MainActor`; parsing runs off it.

`Position` contains a section/page/track index, local progress, optional anchor,
integration-supplied CFI, text context, and timestamp. `Locator` adds href and total
progress. Audio progress is weighted by duration.

`ReaderStateStore` persists position, preferences, bookmarks, and update time.
File storage must accept long IDs, preserve old snapshots, and write atomically.
Temporary-file cleanup must not remove another session's resources.

## Navigation and events

- Support positions, locators, nested TOC, next/previous, bounded back/forward
  history, preferences, bookmarks, and accessibility settings.
- Resolve internal paths, anchors, pages, and timed audio fragments natively.
- Block external URLs by default. `LinkPolicy` selects follow, block, or external
  opening; the host performs external opening.
- Apply the same link policy to reflow, bitmap, and PDF links. Preserve PDFKit
  internal actions and intercept URL annotations.
- Give each event subscriber an independent stream. Coalesce passive WebKit
  positions and suppress duplicates; preserve explicit navigation updates.

## Presentation

| Path | Required behavior |
| --- | --- |
| Reflow | Wait for bootstrap; sanitize markup; disable publication JavaScript; isolate host scripts; validate messages; apply theme, typography, and accessibility; measure layout; intercept links. |
| Fixed pages | Preserve aspect ratio, reading direction, covers, and spreads; report visible pages; map link bounds to view coordinates; supply named accessible targets and host overlays. |
| Thumbnails | Bound cache bytes and prefetch distance. Ignore invalid prefetch indices without overflow. |
| PDF | Report page changes and preserve native internal actions. Use host policy for external links. |
| Audio | Prepare, play/pause, seek, change tracks/rates, publish state, persist position, manage remote commands where available, check protection, and clean up session files. |

The host supplies system accessibility state. Support VoiceOver-aware reading
mode without overwriting saved preferences, reduced motion, optional position
announcements, semantic markup, page labels, and accessible links.

## Acceptance

- Fixtures open or fail with their intended typed error. Assert content and
  behavior, not only absence of errors.
- Reopening preserves IDs and saved state.
- Test protection, resource bounds, navigation, and multi-session ownership.
- Test WebKit and AVFoundation paths with real framework instances.
- Pass the checks in [validation](TEST_COVERAGE.md); keep API examples and support
  claims aligned with code.

## Licensing

BookKit is MIT licensed. Its DjVu decoder follows published format behavior and
independent fixtures. Do not embed, link, or mechanically port DjVuLibre.
Reference projects retain their own licenses and are dependencies only when
listed in `Package.swift`. Preserve notices when adapting permitted code.
