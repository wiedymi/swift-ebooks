# Ebook Library Reference Survey (updated 2026-07-10)

> This is a dated discovery snapshot. Repository popularity figures may change;
> the checked-in submodule revisions and license files are the implementation
> reference source of truth. See [`README.md`](README.md) for current BookKit docs.

This survey focuses on:

- Rust-first parsing libraries
- Widely used ebook engines/toolkits
- License compatibility for an MIT-licensed host project

## Selected References (Added as Submodules)

| Repo | Language | Scope | Popularity Signal | License | Why selected |
|---|---|---|---|---|---|
| `readium/swift-toolkit` | Swift | End-to-end reading toolkit (EPUB/PDF/LCP ecosystem) | 459 GitHub stars | BSD-3-Clause | Mature Swift architecture and publication model reference |
| `futurepress/epub.js` | JavaScript | Browser EPUB rendering and pagination | 6,874 GitHub stars | BSD-style permissive license text (`license` file) | Most-used web EPUB rendering design reference |
| `witekbobrowski/EPUBKit` | Swift | Native EPUB parsing and model mapping | 292 GitHub stars | MIT | Practical Swift-native EPUB parsing reference |
| `DevinSterling/rbook` | Rust | Format-agnostic ebook parsing abstraction (EPUB focus) | 25 GitHub stars | Apache-2.0 | Direct parser API design reference from Rust ecosystem |
| `r-glazkov/fb2` | Rust | FB2 format parser | 5 GitHub stars | MIT | Direct FB2 parsing reference for FictionBook support |
| `vv9k/mobi-rs` | Rust | MOBI format parsing | 40 GitHub stars | MIT | MOBI parsing reference and binary/container handling patterns |
| `zacharydenton/boko` | Rust | EPUB/MOBI/AZW3/KFX conversion and parsing | 4 GitHub stars | MIT | AZW3/KF8 implementation reference for Kindle-family formats |
| `johnfactotum/foliate-js` | JavaScript | Multi-format web reading stack (includes Kindle-family support) | 895 GitHub stars | MIT | Additional AZW3/KF8 behavior reference |
| `mozilla/pdf.js` | JavaScript | Widely used PDF parser + renderer | 52,863 GitHub stars | Apache-2.0 | Primary PDF rendering behavior reference |
| `J-F-Liu/lopdf` | Rust | PDF document parsing/manipulation | 2,057 GitHub stars | MIT | PDF parsing/data-model reference from Rust ecosystem |

## Standards and clean-room format references

| Reference | Use |
|---|---|
| [W3C Audiobooks](https://www.w3.org/TR/audiobooks/) | Manifest reading order, metadata, resources, TOC, duration, and packaged/offline behavior |
| [Official DjVu format documentation](https://djvu.sourceforge.net/doc/man/djvu.html) | Published container, image-layer, text, outline, and annotation behavior for the clean-room decoder |

Standards describe file behavior; they are not linked runtime dependencies.

## Evaluated But Excluded

| Repo | Reason excluded |
|---|---|
| `danigm/epub-rs` | GPL-3.0 license; conflicts with permissive-only dependency policy for this project |
| `kovidgoyal/calibre` | GPL-3.0 license; strong copyleft not suitable as a code reference dependency for MIT-distributed implementation reuse |
| [`DjVuLibre`](https://djvu.sourceforge.net/licensing.html) | GPL-2.0 licensing is incompatible with embedding or mechanically porting its decoder into this MIT package. BookKit uses its command-line tools only as an external black-box compatibility oracle during development, never as a library/runtime dependency. |

## License Decision Rule Used

Allowed in `refs/`:

- MIT
- BSD-2-Clause / BSD-3-Clause (or equivalent BSD-style permissive text)
- Apache-2.0

Rejected in `refs/`:

- GPL, AGPL, LGPL/copyleft-first licenses for implementation reference reuse

## Notes

- This repository keeps these projects as `git submodule`s for architecture study and non-copy reference.
- If code is ever ported or adapted, preserve each upstream license notice and attribution requirements.
- The BookKit DjVu implementation is clean room: it follows published format
  behavior and independent fixtures and does not inspect/copy DjVuLibre decoder
  source.
