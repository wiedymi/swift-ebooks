# BookKit product specification

Date: 2026-07-10

This document defines the public product contract. See
[`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) for exact compatibility
boundaries and current test evidence.

## Objective

BookKit provides one native Swift API for:

- opening supported DRM-free publications inside Apple app sandboxes;
- normalizing text, fixed-page, PDF, and timed-audio formats into one model;
- presenting reflowable, fixed-page, PDF, and audiobook content;
- navigating with positions, timestamps, TOC entries, page/track movement, and
  bounded history;
- exposing live state to host UI;
- persisting position, preferences, and bookmarks;
- letting trusted host code add narration, annotations, analytics, or other
  product behavior without trusting publication JavaScript.

## Supported product paths

| Path | Contract |
| --- | --- |
| EPUB | EPUB 2/3 reflowable and pre-paginated/image-only content with OPF, nav/NCX, local styles/assets, TOC, landmarks, and page list |
| FB2 | Structured FB2 and single-document `.fb2.zip` with metadata, sections, notes, styles, and embedded images |
| Kindle | DRM-free MOBI 6 and supported AZW3/KF8 PalmDOC/FDST flows |
| PDF | Unencrypted PDFKit-backed pages, metadata, outlines, page list, page callbacks, and policy-routed URL links |
| Image books | CBZ, image-only EPUB, and decoded DjVu through the fixed-page engine |
| DjVu | Clean-room parsing/decoding of the documented bundled visual/text/navigation path |
| Document adapters | TXT, standalone HTML, and Markdown converted to safe reflow content |
| Audiobooks | W3C/Readium manifests, packaged audio, and supported standalone audio through AVFoundation |
| Reflow UI | `WebViewReflowBridge` plus `BookView` |
| Fixed UI | `FixedPageBookView`, `FixedPageAdapter`, and `ImagePageStore` |
| PDF UI | `PDFBookView` on iOS, macOS, and visionOS |
| Audio | `AudiobookPlayer`, `AudiobookTimeline`, and `AVFoundationAudiobookEngine` |

Supported platforms:

- iOS 16+
- macOS 13+
- tvOS 16+
- visionOS 1+
- Swift tools 6.2+

## Non-goals

- Any DRM decryption, password handling, key acquisition, license processing, or
  access-control circumvention
- CBR/RAR
- Executing scripts supplied by a publication
- A web-site downloader or general browser
- Canonical EPUB CFI generation
- Complete proprietary Kindle recovery for every producer variant
- Automatic OCR for scanned/image books
- Ebook authoring/export
- A package-owned application shell; the reference app is an integration example

## Design invariants

1. `Book` is the format-independent source of truth.
2. Layout differences are typed as reflowable, fixed, or audiobook presentation.
3. Parser-specific state does not leak into general navigator control flow.
4. Disk, network, temporary storage, and resource limits are explicit.
5. Network access and publication JavaScript are disabled by default.
6. Protected content fails with `BookError.protectedContent`; it is never passed
   to a decryption workflow.
7. WebKit, PDFKit, and playback coordination remain main-actor isolated.
8. Mutable reader state is actor-owned and persistable through a protocol.
9. Positions and locators are deterministic and serializable.
10. Every event consumer receives an independent stream.
11. Internal destinations use native navigation; external URLs use host policy.
12. Unsupported compatibility boundaries are documented rather than silently
    advertised as complete support.

## Source and resource contract

```swift
public enum BookSource: Sendable {
    case url(URL)
    case data(Data, fileName: String?)
    case stream(fileName: String?, provider: @Sendable () throws -> Data)
}
```

The default URL policy supports app-container and security-scoped picker URLs.
The provider is deferred but not incrementally parsed; current parsers materialize
the complete source as `Data`.

`OpenOptions` controls:

- network opt-in;
- file-access policy;
- app-owned temporary directory;
- source byte limit;
- per-resource byte limit;
- aggregate archive expansion limit;
- archive entry-count limit.

Archive readers must reject encrypted entries, unsafe paths, excessive counts,
oversized resources, and excessive aggregate expansion before normal extraction.

## Protection contract

BookKit has no API that accepts a password, DRM license, or decryption key.

- ZIP encryption is rejected before extraction.
- EPUB allows IDPF font obfuscation because it is resource transformation, not a
  reading-access DRM scheme; every other declared encryption algorithm is
  rejected.
- Kindle encryption, encrypted PDF, protected audio, and Secure DjVu are
  rejected before their normal decode/render path.
- Native framework support does not weaken this policy.

The protection error should retain the detected kind, scheme, and affected
resource when available so applications can explain the failure without trying
to unlock it.

## Normalized model

`Book` contains:

- stable ID, detected format, and format version;
- normalized metadata;
- ordered reading order;
- local or referenced assets;
- nested TOC, landmarks, and page list;
- presentation layout/progression/spread data;
- namespaced raw extensions;
- non-fatal diagnostics.

Fixed pages may include pixel dimensions and top-left-origin `PageLink` bounds.
Audio chapters may include duration and clip boundaries.

## Position and navigation contract

`Position` supports:

- section/page/track index;
- local progression from zero through one;
- anchor and optional integration-supplied CFI;
- text context;
- audiobook timestamp.

`Locator` adds the section href and total-publication progression. Audiobook total
progress is weighted by track duration, not track count.

The navigator must support locators, TOC items, next/previous movement,
back/forward history, preferences, accessibility settings, and link routing.
Audiobook media fragments such as `#t=70` and `#t=npt:01:10` resolve to timed
positions.

## Presentation contracts

### Reflow

The built-in bridge must sanitize content, wait for bootstrap readiness, apply
theme/typography/accessibility state, measure actual WebKit geometry, intercept
links, validate bridge messages, and isolate host plug-ins from the page world.

### Fixed pages

`FixedPageBookView` must:

- preserve page aspect ratio;
- honor LTR/RTL spread order and cover/center pages;
- expose the currently visible page indexes and locator;
- map source-pixel bounds into fitted view coordinates;
- expose named accessible link targets;
- permit an arbitrary host overlay without owning its state.

`ImagePageStore` must keep thumbnail memory bounded and cap prefetch distance.

### PDF

`PDFBookView` must keep PDFKit's internal page actions, report current-page
changes, and intercept URL annotations for host policy rather than opening them
implicitly.

### Audiobook

`AudiobookPlayer` must provide preparation, playback/pause, exact seeking,
track transitions, rates, events, bookmarks, persistence, Now Playing/remote
commands where available, protected-asset checks, and temporary-resource cleanup.

## Event contract

`NavigatorEvent` covers readiness, locators, page maps, selection, content size,
history, reading mode, preferences, accessibility, links, decoration taps,
custom bridge messages, and errors.

`AudiobookPlaybackEvent` covers readiness, state, live time, track changes, end,
and errors.

Streams are broadcast: a slow or cancelled consumer cannot take events from
another consumer. Passive WebKit positions are animation-frame coalesced and
duplicates are suppressed.

## Persistence contract

`ReaderStateStore` loads/saves a `ReaderSnapshot` keyed by deterministic book ID.
It contains position (including timestamp), bookmarks, preferences, and update
time. BookKit supplies in-memory and file implementations; hosts may provide a
database, app-group, or cloud implementation.

## Link contract

- Internal anchors/pages/tracks follow native navigation.
- External URLs are blocked by `DefaultLinkPolicy`.
- A host may return `.openExternally`, but the host performs the actual open.
- `javascript:`, `file:`, and unknown schemes remain blocked by default.
- Fixed-page and reflow links use the same `ContentRenderer` policy/history path.
- PDF URL annotations are intercepted before PDFKit's default opener.

## Accessibility contract

The host observes system accessibility state and supplies policy. BookKit
supports VoiceOver-aware reflow mode, reduced motion, optional live position
announcements, semantic source markup, page labels/values, accessible fixed-page
links, and host overlays for narration focus.

## Acceptance criteria

1. Every checked-in fixture opens or fails with its intended typed error.
2. Stable publication IDs survive reopening.
3. Each supported format has semantic assertions beyond “did not throw.”
4. Protection paths reject before protected content is rendered or played.
5. Reflow, fixed, PDF, and audio navigation are deterministic and persistable.
6. TOC and link behavior is integration tested across the applicable surfaces.
7. Live WebKit and AVFoundation paths use real framework instances in tests.
8. Archive and decoder limits have deterministic coverage.
9. `swift test`, release build, diff checks, and declared-platform builds pass.
10. The reference app compiles and provides deterministic demo-path readiness.
11. `IMPLEMENTATION_STATUS.md` remains aligned with actual behavior.

## Licensing

BookKit is MIT licensed. The DjVu decoder is a clean-room implementation based on
published format behavior and independently generated/black-box fixtures. It does
not embed, link, or mechanically port DjVuLibre. Reference projects remain under
their own licenses and are not library dependencies unless declared in
`Package.swift`.
