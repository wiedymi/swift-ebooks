# Reference Submodules

This folder contains upstream projects used as implementation and architecture references for `BookKit`.

All included references are permissive-licensed (MIT/BSD/Apache), compatible with an MIT-licensed host project.

## Included Repositories

| Path | Upstream | License | Pinned commit |
|---|---|---|---|
| `refs/readium-swift-toolkit` | https://github.com/readium/swift-toolkit | BSD-3-Clause | `353cd46e257a2a153b1ff161f188305ac66cfd34` |
| `refs/epubjs` | https://github.com/futurepress/epub.js | BSD-style permissive (`license` file) | `f09089cf77c55427bfdac7e0a4fa130e373a19c8` |
| `refs/epubkit` | https://github.com/witekbobrowski/EPUBKit | MIT | `dd1bcc200376f23dd75c12d1f5968f96a9c0e0b7` |
| `refs/rbook` | https://github.com/DevinSterling/rbook | Apache-2.0 | `d4663c59bc4fe0caf45c5e60dce98c35f4dab8fb` |
| `refs/fb2-rs` | https://github.com/r-glazkov/fb2 | MIT | `023f17b4268f71f27734234ab841e24d0b0abdd4` |
| `refs/mobi-rs` | https://github.com/vv9k/mobi-rs | MIT | `bc332dc6d1982b30760b2bf9d164c64c552e30a0` |
| `refs/boko` | https://github.com/zacharydenton/boko | MIT | `bd17d8fbe8505397c59d4947dc9212b32b2bfcbb` |
| `refs/foliate-js` | https://github.com/johnfactotum/foliate-js | MIT | `6b11e1744346f60504b727984f7d42f0fef3ab54` |
| `refs/pdfjs` | https://github.com/mozilla/pdf.js | Apache-2.0 | `5bb35eeb35ff92d62b007b02c50f525e35e1cc5d` |
| `refs/lopdf` | https://github.com/J-F-Liu/lopdf | MIT | `0387137b90d54418db02ccc0b406ed6a5883da0d` |

## Update Procedure

```bash
git submodule update --init --recursive
git submodule update --remote refs/<name>
```

If adding new references, keep the same permissive license policy and record the decision in `docs/REFERENCE_SURVEY.md`.
