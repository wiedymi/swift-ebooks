# Test coverage

BookKit uses deterministic unit tests, live WebKit integration tests, and a
checksum-pinned real-book corpus. A passing build is evidence for the documented
support matrix, not evidence of complete compatibility with every ebook producer.

## Standard validation

```bash
git submodule update --init --recursive
./scripts/verify_corpus.sh
swift test
swift build -c release
```

`verify_corpus.sh` checks each fixture's SHA-256 digest and byte size before parser
tests use it.

## Unit coverage

The unit suite covers:

- extension/signature format detection;
- source, resource, and archive-size policy;
- sandbox and network defaults;
- HTML/CSS sanitization and normalization idempotence;
- preformatted-whitespace preservation;
- link classification and native policy behavior;
- position, locator, page-map, history, and preference behavior;
- state-store and bookmark round trips;
- multi-subscriber event delivery and owner lifecycle;
- navigation href and anchor resolution;
- bridge payload validation, including typed custom messages;
- reflow layout command/event mapping;
- PDF page/index conversion.

## Live WebKit coverage

`WebViewReflowBridgeTests` creates real offscreen `WKWebView` instances. It verifies:

- bootstrap readiness and initial-load ordering;
- bridge-to-native event delivery;
- app-world isolation from the publication page world;
- multiple independent event subscribers;
- custom command registration, return values, and typed events;
- content lifecycle hooks;
- accessibility state reaching the rendered document;
- deterministic progression commands and live position events;
- publication links reaching native `ContentRenderer` navigation.

These are integration tests against WebKit, not a mocked JavaScript interpreter.

Run only that surface on macOS:

```bash
swift test --filter WebViewReflowBridgeTests
```

## Corpus coverage

The manifest is `tests/corpus/manifest.tsv`.

| Fixture | Purpose |
| --- | --- |
| `epictetus.epub` | Real EPUB container, metadata, assets, CSS, hierarchical nav, landmarks, and search |
| `epictetus.mobi` | PalmDOC/MOBI records, metadata, file-position links, images, and search |
| `epictetus.azw3` | KF8 flows, multiple sections, styles, embedded images, and search |
| `complex.fb2` | Structured metadata, nested sections, poem markup, notes, and binaries |
| `helloworld.pdf` | PDF metadata/page ingestion and adapter smoke coverage |

Corpus tests reopen publications to verify stable IDs and assert semantic content
rather than only checking that parsing did not throw.

## Platform builds

The package declares iOS 16, macOS 13, tvOS 16, and visionOS 1. Build the example
scheme for simulator SDKs to catch conditional compilation errors:

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

`swift test` and `swift build -c release` cover the macOS SwiftPM configuration.

## Runtime smoke

The example accepts a deterministic file path and prints a readiness marker after
open, renderer construction, state restore, first render, and position refresh:

```bash
swift run BookKitExample --demo tests/corpus/files/epictetus.epub
```

Expected prefix:

```text
BOOKKIT_EXAMPLE_READY format=epub
```

The same path can exercise `.fb2`, `.mobi`, `.azw3`, and `.pdf` fixtures.

## Release gate

Before tagging a release:

1. verify the corpus;
2. run the complete test suite;
3. run the release build;
4. compile `BookKitExample` for every declared Apple platform;
5. launch at least one reflowable fixture and one PDF fixture through `--demo`;
6. confirm `docs/IMPLEMENTATION_STATUS.md` still matches parser behavior;
7. confirm `git diff --check` is clean.

## Known test boundaries

The repository does not yet claim:

- visual snapshot coverage for every typography/viewport combination;
- automated VoiceOver rotor or spoken-output verification;
- performance baselines with median/p95/p99 parse and pagination measurements;
- large adversarial archive and fuzzing coverage;
- broad commercial-book compatibility for proprietary Kindle variants;
- fixed-layout EPUB, media-overlay, DRM, or OCR verification.

Those gaps correspond to the roadmap in
[`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md).
