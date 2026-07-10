# BookKit documentation

BookKit is a native Swift package for opening, normalizing, navigating, and
rendering ebook publications on Apple platforms.

## Developer guides

- [`API.md`](API.md) — opening books, constructing renderers, navigation,
  persistence, accessibility, decorations, links, search, and PDF presentation
- [`BRIDGE_EXTENSIONS.md`](BRIDGE_EXTENSIONS.md) — trusted host plug-ins,
  app-to-JavaScript commands, JavaScript-to-app messages, and lifecycle hooks
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — ownership boundaries from source loading
  through parsing, normalization, navigation, and platform views

## Scope and verification

- [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) — source of truth for
  tested format behavior and unsupported features
- [`TEST_COVERAGE.md`](TEST_COVERAGE.md) — unit, WebKit, corpus, release, and
  platform-build validation
- [`SPEC.md`](SPEC.md) — v1 product scope, invariants, and acceptance criteria
- [`REFERENCE_SURVEY.md`](REFERENCE_SURVEY.md) — permissive-license projects used
  for architecture and behavioral comparison

## Start here

For a first integration, read the root [`README`](../README.md), then use
[`API.md`](API.md). Read [`BRIDGE_EXTENSIONS.md`](BRIDGE_EXTENSIONS.md) only if
the app needs DOM-level behavior such as text-to-speech focus, custom selection
handling, reading analytics, or another host-owned feature.
