# swift-ebooks

Direct Swift ebook parsing, processing, and rendering library specification.
Sandbox-compatible by design (iOS/macOS/app-extension friendly).

## Current status

- Reference survey completed: `docs/REFERENCE_SURVEY.md`
- Architecture spec finalized (v1.0): `docs/SPEC.md`
- Upstream references added as submodules in `refs/`
- Core reader APIs implemented with tests:
  - unified `Navigator` surface (`ContentRenderer`) across formats
  - `Locator` model (`section + progression + anchor`)
  - runtime reading mode switch (`scroll` / `paginated`)
  - jump history (`goBack` / `goForward`)
  - decoration groups (highlights/search/TTS markers) + tap events
  - persisted reader preferences (mode/theme/typography/position/bookmarks)
  - VoiceOver-aware accessibility API (`ReaderAccessibilitySettings`)

Target package name in spec: `BookKit`

v1.0 formats in scope:

- EPUB 2/3
- FB2
- MOBI
- AZW3/KF8 (unencrypted)
- PDF (read-only adapter)

## Bootstrap references

```bash
git submodule update --init --recursive
```

## Test Corpus

Open end-to-end parser assets are defined in `tests/corpus/manifest.tsv`.

```bash
git submodule update --init --recursive
./scripts/verify_corpus.sh
```

Run unit + E2E tests:

```bash
swift test
```

## Example App

`BookKitExample` is a SwiftUI demo app that can:
- open ebook files from disk
- show metadata and a best-effort poster image
- render content with the built-in reader demo
- add/remove persistent bookmarks and restore reading position

Build/run:

```bash
swift run BookKitExample
```

You can also open the package in Xcode and run the `BookKitExample` scheme.

## License

MIT (`LICENSE`), with upstream licenses preserved in each `refs/*` submodule.
