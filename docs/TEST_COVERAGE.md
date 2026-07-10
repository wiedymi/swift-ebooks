# Test coverage

BookKit combines deterministic format/unit tests, live framework integration, and
a checksum-pinned real-book corpus. Passing tests prove the documented paths, not
universal compatibility with every producer.

## Standard validation

```bash
git submodule update --init --recursive
./scripts/verify_corpus.sh
swift test
swift build -c release
git diff --check
```

## Format and model coverage

The unit suite covers:

- extension/signature detection for every `BookFormat`;
- EPUB reflow and image-only/fixed presentation, navigation, resources, and font
  obfuscation;
- FB2 ZIP single-document rules;
- CBZ natural order, ComicInfo, cover, bookmark, spread, and manga RTL behavior;
- TXT/HTML/Markdown conversion, escaping, links, and nested generated TOC;
- W3C/Readium/packaged/standalone audio metadata, media fragments, assets, and
  DRM markers;
- audiobook timeline, duration-weighted locators, playback transitions, rate,
  seeking, persistence, bookmarks, and native protected-asset checks;
- DjVu IFF, DIRM/INCL, BZZ/ZP, IW44, JB2/shared dictionaries, regular and striped
  MMR, palettes, page composition, text, outline, annotations, relative links,
  and Secure DjVu rejection;
- fixed-page spread mapping, source/view geometry, accessible line hit targets,
  real ImageIO thumbnails, bounded caching, and prefetch;
- PDF page/position and custom-scheme outline navigation;
- normalized timed/fixed model encoding and defaults.

## Protection and adversarial coverage

Deterministic tests verify:

- ZIP encryption flags and decryption headers;
- unknown EPUB encryption versus allowed IDPF font obfuscation;
- Kindle and PDF protection paths through their parser checks;
- audiobook manifest protection and playback-engine protected failures;
- Secure DjVu signature rejection;
- source/resource/archive entry/aggregate limits;
- unsafe or malformed container structures;
- bounded DjVu output, record, chunk, nesting, and dimension checks;
- offline resource behavior and security-scoped file policy.

## Reader and navigation coverage

- position/locator/page-map conversion;
- duration-weighted audiobook progress and timed TOC fragments;
- TOC activation for relative EPUB paths and PDF custom-scheme hrefs;
- reflow, fixed-page, PDF, and audio next/previous behavior;
- native fixed-page link routing through policy/history;
- back/forward history;
- state-store and bookmark round trips;
- multiple independent event subscribers and owner lifecycle;
- accessibility preferences without overwriting saved reading mode;
- decoration application/tap events;
- link classification and default policy.

## Live WebKit coverage

`WebViewReflowBridgeTests` creates real offscreen `WKWebView` instances and
verifies:

- bootstrap readiness and initial command ordering;
- client-world isolation from publication page scripts;
- independent subscribers;
- custom commands, return values, events, and content lifecycle hooks;
- accessibility state reaching the document;
- deterministic progression commands and live position events;
- publication links reaching `ContentRenderer` native navigation.

Run only that surface:

```bash
swift test --filter WebViewReflowBridgeTests
```

## AVFoundation coverage

The suite uses:

- an injected fake `AudiobookPlaybackEngine` for deterministic load/play/pause,
  time, rate, end, track transition, and failure state;
- a small real unprotected MP3 for AVFoundation inspection, playability,
  duration, and engine loading;
- a protected-engine failure fixture to prove prepare never proceeds.

Automated tests do not assert audible speaker output or system lock-screen UI.

## Corpus coverage

`tests/corpus/manifest.tsv` pins checksum and size for:

| Fixture | Purpose |
| --- | --- |
| `epictetus.epub` | Real EPUB metadata, resources, CSS, nested nav, landmarks, and search |
| `epictetus.mobi` | PalmDOC/MOBI records, metadata, file-position links, images, and search |
| `epictetus.azw3` | KF8 flows, multiple sections, styles, images, and search |
| `complex.fb2` | Metadata, nested sections, poetry, notes, and binaries |
| `helloworld.pdf` | PDF metadata/page ingestion and adapter smoke coverage |

Corpus assertions inspect semantic results rather than only non-throwing parse,
and publications are reopened to verify stable IDs.

Compact generated fixtures cover the newer CBZ, fixed EPUB, document, audiobook,
and DjVu paths without adding large binary test assets to the repository.

## Platform builds

The package declares iOS 16, macOS 13, tvOS 16, and visionOS 1. Build the example
for simulator SDKs to catch conditional compilation:

```bash
xcodebuild -scheme BookKitExample \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -scheme BookKitExample \
  -destination 'generic/platform=tvOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -scheme BookKitExample \
  -destination 'generic/platform=visionOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

`swift test` and `swift build -c release` cover macOS SwiftPM.

## Runtime smoke

The example accepts a deterministic source and prints readiness after parsing,
renderer/player construction, restoration, and first presentation setup:

```bash
swift run BookKitExample --demo tests/corpus/files/epictetus.epub
```

Expected prefix:

```text
BOOKKIT_EXAMPLE_READY format=epub
```

The same path can exercise any locally available supported DRM-free file.

## Release gate

1. verify the pinned corpus;
2. run the complete test suite;
3. run a release build;
4. compile the example for every declared platform;
5. run demo-path smoke for reflow, fixed-page, PDF, and audiobook inputs when
   fixtures are available;
6. confirm README/status/API match parser behavior;
7. confirm no temporary oracle/generated files are tracked;
8. confirm `git diff --check` is clean.

## Known test boundaries

- no exhaustive visual snapshots for every typography/viewport/image format;
- no automated VoiceOver rotor or spoken-output assertion;
- no audible-output/lock-screen UI automation;
- no full fuzzing campaign yet;
- no large checked-in commercial DjVu or audiobook corpus;
- no claim of broad compatibility for rare Kindle, indirect DjVu, or vendor EPUB
  extensions;
- no CBR, DRM, OCR, canonical CFI, or EPUB media-overlay verification because
  those are outside the implemented contract.
