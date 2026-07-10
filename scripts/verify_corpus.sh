#!/usr/bin/env bash
set -euo pipefail

manifest="tests/corpus/manifest.tsv"

if [[ ! -f "$manifest" ]]; then
  echo "Missing manifest: $manifest" >&2
  exit 1
fi

errors=0
count=0

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    echo "No SHA-256 tool found (need shasum or sha256sum)." >&2
    return 1
  fi
}

while IFS=$'\t' read -r id format path expected_sha expected_bytes license source notes; do
  if [[ -z "${id:-}" || "$id" == \#* ]]; then
    continue
  fi

  count=$((count + 1))

  if [[ ! -f "$path" ]]; then
    echo "[FAIL] $id ($format): missing file at $path" >&2
    errors=$((errors + 1))
    continue
  fi

  actual_sha="$(sha256_file "$path")"
  actual_bytes="$(wc -c < "$path" | tr -d ' ')"

  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "[FAIL] $id ($format): sha256 mismatch" >&2
    echo "  expected: $expected_sha" >&2
    echo "  actual:   $actual_sha" >&2
    errors=$((errors + 1))
  fi

  if [[ "$actual_bytes" != "$expected_bytes" ]]; then
    echo "[FAIL] $id ($format): size mismatch" >&2
    echo "  expected: $expected_bytes" >&2
    echo "  actual:   $actual_bytes" >&2
    errors=$((errors + 1))
  fi

  if [[ "$actual_sha" == "$expected_sha" && "$actual_bytes" == "$expected_bytes" ]]; then
    echo "[OK] $id ($format) $actual_bytes bytes"
  fi
done < "$manifest"

if [[ "$count" -eq 0 ]]; then
  echo "No corpus entries found in $manifest" >&2
  exit 1
fi

if [[ "$errors" -gt 0 ]]; then
  echo "Corpus verification failed: $errors issue(s)." >&2
  exit 1
fi

echo "Corpus verification passed for $count entries."
