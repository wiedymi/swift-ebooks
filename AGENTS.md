# Working rules

Keep replies short. Use ASD-STE100 Simplified Technical English.

- Audit or review: inspect, reproduce, and report. Do not change files.
- Fix or implement: complete the change and relevant checks within the requested scope.
- Make routine choices without asking. Ask only when missing information changes the result.
- Preserve unrelated edits. Commit or push only when asked.
- Compare practical options. Choose the simplest correct option. State its costs and limits.
- Derive state when possible. Remove duplicate branches and unnecessary types.
  Use an enum for a closed set of states.
- Check size limits, indices, arithmetic overflow, cancellation, and resource ownership.
- Keep comments that explain contracts, algorithms, or non-obvious constraints.
  Remove comments that repeat the code.

## Project map

- `Sources/BookKit`: library. `BookReader` owns a session; `BookReaderView` selects its UI.
- `ReaderStateActor`: one shared state owner for navigation and playback.
- `BookParser` / `ParserRegistry`: format parsing into `Book`.
- `ContentRenderer`, reflow, fixed-page, PDF, and audio files: internal engines.
- `tests/BookKitTests`: unit and live framework tests. `tests/corpus`: pinned fixtures.
- `Examples/BookKitExample`: reference app.
- `refs`: external reference submodules. Do not edit or update them unless asked.

Read [architecture](docs/ARCHITECTURE.md), [contracts](docs/SPEC.md), and
[support limits](docs/IMPLEMENTATION_STATUS.md) for the affected path.
Keep [API examples](docs/API.md) aligned with public code.

## Required behavior

- Open DRM-free content only. Keep protection checks before decoding and playback.
- Keep network access off by default. Enforce it in WebKit, not only text filtering.
- Apply byte limits during file and network reads; check archive and decoder expansion.
- Keep framework-facing state on `@MainActor`; keep parsing off it.
- A session must not delete another session's files.
- Keep persistent IDs stable and read existing state files.
- Do not copy or port DjVuLibre. Preserve upstream license notices and attribution.

## Checks

Use Swift 6.2+ and Xcode with the required Apple SDKs. From the repository root:

```sh
git submodule update --init --recursive
./scripts/verify_corpus.sh
swift test --filter <AffectedTests>
swift test
swift build -c release
git diff --check
```

Run focused tests while editing, then the full suite and release build once the
change is ready. For platform or framework changes, run the simulator build
commands in [validation](docs/TEST_COVERAGE.md). Report checks that could not run.
Add a regression test for each confirmed bug. Separate reproduced failures,
static findings, and measured performance results. Do not add benchmark claims
without measurements.

forbidden words: locus, load-bearing, quiescence, quiesce, glass-break, dead-letter, spool, rung, envelope, high-water, gauntlet, fence, receipt, generation, ceremony, belt-and-suspenders.
