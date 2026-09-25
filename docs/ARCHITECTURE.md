# Architecture

## Ownership

```text
BookSource + OpenOptions
  -> FormatSniffer -> ParserRegistry -> Book
  -> BookReader + one ReaderStateActor
     -> ContentRenderer -> ReflowLayout -> WebViewReflowBridge
                        -> PDFPageAdapter + PDFBookView
                        -> FixedPageAdapter + FixedPageBookView
     -> AudiobookPlayer -> AudiobookPlaybackEngine
  -> BookReaderView
```

`BookReader` owns engine selection, navigation, published state, events, and
session lifetime. The host owns app controls, external URL opening, annotation
storage, and custom voice services. Optional system speech is owned by
`ReaderSpeechController`.

`BookReader` and framework-facing engines run on `@MainActor`. Parsing runs off
the main actor. `ReaderStateActor` owns position, preferences, bookmarks, and
persistence. Navigation and audio share that single state actor.

## Sources and parsers

`Book.open` reads the source, detects its format, selects a parser, and maps
failures to `BookError`. Parsers produce `Book`, ordered chapters, assets,
metadata, navigation, presentation details, and recoverable diagnostics.

`BoundedDataReader` reads files in chunks and remote data through `URLSession`
bytes. It stops at the configured limit and cancels remote transfers on exit.
Parsers still require the complete accepted source in memory. A caller-supplied
`Data` or provider has already allocated its payload before size validation.

`SafeZIPArchive` checks encryption, paths, entry counts, resource sizes, and total
expansion for CBZ, FB2 ZIP, and packaged audio. EPUB applies package-specific
checks. Protection checks run before normal decoding. Audio also checks native
protection status before playback where the platform supports it.

## Presentation

| Path | Responsibility |
| --- | --- |
| Reflow / XHTML fixed | `ReflowLayout` maps commands and events; `WebViewReflowBridge` owns WebKit, layout measurement, and trusted scripts. |
| Bitmap fixed | `FixedPageAdapter` maps pages and spreads; `FixedPageBookView` fits images, link targets, and host overlays. |
| PDF | `PDFParser` retains the document asset; `PDFBookView` preserves internal actions and reports external links to host policy. |
| Audio | `AudiobookTimeline` maps clip times and weighted progress; `AudiobookPlayer` owns playback, remote commands, and cleanup. |

`ReflowPageTurnRuntime` owns transient snapshots for paginated next/previous
turns. `PageTurnSurface` draws slide or paper-curl frames with Core Image and
Metal; it does not hold navigation state or change the document layout.

The reflow bridge uses non-persistent WebKit storage and an isolated client
script world. Publication JavaScript is disabled. Text filtering removes active
markup; WebKit content rules block network resources in offline mode, including
URLs decoded from HTML entities or CSS escapes.

HTML asset URLs are encoded when the current chapter needs them. PDF, bitmap,
and audio sessions do not create Base64 copies of their assets.

`ImagePageStore` owns a byte-limited thumbnail cache. Prefetch accepts valid page
indices and a radius of at most eight pages. Fixed-page link bounds use source
pixels with a top-left origin; the view converts them to fitted coordinates.

Each `AudioResourceStore` owns a separate temporary folder. Cleanup removes only
that session's files. The same book in two sessions can therefore use more disk
space. Call `BookReader.shutdown()` when a session ends.

## DjVu

```text
IFF / DIRM / INCL -> BZZ + ZP -> IW44 / JB2 / MMR / JPEG
  -> composed and rotated page -> JPEG or PNG asset
```

NAVM supplies navigation, TXTa/TXTz supplies OCR text, and ANTa/ANTz supplies page
links. Decoder sizes, records, component counts, and nesting have limits.
BookKit does not embed or port DjVuLibre.

## Events and persistence

WebKit events pass through `ReflowLayout` and `ContentRenderer` to `BookReader`.
Native PDF, bitmap, and audio callbacks update the same reader state. Each event
subscriber has its own buffer. Passive positions are coalesced; explicit
navigation updates remain observable.

`ReaderStateStore` loads and saves position, timestamps, preferences, bookmarks,
and update time. `FileReaderStateStore` uses SHA-256 filenames and atomic writes.
It can read older hex-encoded filenames; subsequent saves use the new name.

## Extension points

| Need | API |
| --- | --- |
| Custom parser | `BookParser` / `ParserRegistry` |
| File access | `FileAccessPolicy` |
| Database or cloud state | `ReaderStateStore` |
| External links | `LinkPolicy` |
| Trusted DOM behavior | `ReflowScriptPlugin` |
| Fixed-page overlays | `FixedPageBookView` overlay builder |

See [API.md](API.md) for examples and [SPEC.md](SPEC.md) for required behavior.

## Text features

SwiftSoup extracts HTML text; `NormalizedText` defines whitespace and native UTF-16
mapping. Search, sentence extraction, and PDF selection share this path. Reflow
keeps a matching DOM text map and resolves quotes with surrounding context.
Marks wrap only selected text and preserve the original semantic elements.

`ReaderSpeechController` owns one cancellable reading task and a session-owned
`ReaderSpeechEngine`. The system engine isolates AVFoundation state on the main
actor and transfers only immutable request IDs and ranges from delegate callbacks.
The host can use the same text and locators with another speech or dubbing service.

Passive scroll saves wait 300 ms. Explicit saves capture the current native
position; writes are serialized by the shared state actor. Closing a reader stops
speech, completes pending viewport work, and saves state before cleanup.
