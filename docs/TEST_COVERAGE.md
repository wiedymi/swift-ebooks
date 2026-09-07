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
| State | Long and Unicode IDs, old state filenames, and updated snapshots. |
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
