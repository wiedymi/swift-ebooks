# E2E Corpus

This corpus provides open sample files for end-to-end parser/rendering tests.

## Canonical Manifest

- `tests/corpus/manifest.tsv`

Each row records:

- format
- canonical test path
- SHA-256 checksum
- size
- source and license context

## Files

`tests/corpus/files/*` are symlinks to pinned files inside `refs/*` submodules.

This keeps the corpus reproducible while avoiding duplicate binary storage.

## Verification

```bash
git submodule update --init --recursive
./scripts/verify_corpus.sh
```

The command validates file existence, byte size, and SHA-256 for each manifest entry.
