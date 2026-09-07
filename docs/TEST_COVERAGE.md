# Validation

Run from the repository root:

```bash
git submodule update --init --recursive
./scripts/verify_corpus.sh
swift test
swift build -c release
git diff --check
```

Run a focused suite during development:

```bash
swift test --filter WebViewReflowBridgeTests
```

## Coverage

| Area | Evidence |
| --- | --- |
| Formats | Parser, metadata, navigation, asset, and unsupported-input tests for every supported format. |
| Containers | Encryption, unsafe paths, entry counts, per-resource limits, and total expansion. |
| DjVu | IFF, BZZ/ZP, IW44, JB2, MMR, shared components, text, navigation, and page links. |
| Reader | Engine selection, positions, history, preferences, bookmarks, links, and independent event subscribers. |
| WebKit | Real offscreen views: script isolation, commands, hooks, accessibility, positions, and offline HTTP blocking. |
| Audio | Fake-engine transitions plus real AVFoundation inspection and silent-MP3 playback. Separate-session file cleanup. |
| Resources | File read boundaries, oversized HTTP responses, exact limits, and HTTP errors. |
| State | Long and Unicode IDs, old files, scroll saving, native position capture, and ordered writes. |
| Text | Unicode search, all matches, bounds, quote recovery, overlapping marks, retained selection, and native PDF text/marks. |
| Speech | Custom engine text/ranges, pause/resume, replacement, stop, failures, and startup before view creation. |
| Fixed pages | Geometry, spreads, thumbnails, cache limits, and invalid/extreme prefetch indices. |
| Corpus | Five checksum-pinned EPUB, MOBI, AZW3, FB2, and PDF files in `tests/corpus/manifest.tsv`. |

Network tests use a local HTTP server. They require no external service.

## Platform builds

```bash
xcodebuild -scheme BookKitExample \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme BookKitExample \
  -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme BookKitExample \
  -destination 'generic/platform=visionOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

CI runs corpus checks, tests, a release build, and these platform builds.

For a runtime smoke check:

```bash
swift run BookKitExample --demo tests/corpus/files/epictetus.epub
```

Expected marker: `BOOKKIT_EXAMPLE_READY format=epub`.
Before release, also check PDF, fixed-page, and audio presentation with available
fixtures, and confirm the API and support documents match the implementation.

## Limits

The suite does not prove universal file compatibility. It does not include a full
fuzz campaign, exhaustive visual comparisons, VoiceOver speech checks, audible
output checks, or lock-screen UI automation. Commercial DjVu/audio coverage is
limited. Unsupported features are listed in
[IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md).

## Text rendering measurement

```bash
BOOKKIT_MEASURE_TEXT=1 swift test --filter ReadingTextPerformanceTests
```

The opt-in WebKit workload uses 2,000 paragraphs, 158,889 normalized UTF-16 units,
200 marks, an 800 by 600 viewport, five warm-up runs, and 30 measured updates.
An update includes DOM marks and a layout read. On an Apple M1 Pro with macOS 27.0
(26A5421a), the range-scan implementation measured 15 ms median, 18 ms p95, and
19 ms p99. The ordered-range implementation measured 9 ms median, 10 ms p95,
and 12 ms p99 in the same session. These are local workload results, not device
or frame-rate guarantees. Set `BOOKKIT_TEXT_REPORT` to a file path to save JSON.
