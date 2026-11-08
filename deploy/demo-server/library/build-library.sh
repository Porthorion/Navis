#!/usr/bin/env bash
# Builds the CC0/public-domain demo library into <output-dir>: downloads each source in
# manifest.tsv, verifies its sha256 (fails on mismatch), then tags, adds ReplayGain, lyrics
# and covers inside a pinned container. Re-runnable; downloads are cached next to the output.
# Usage: build-library.sh <output-dir>      (host needs only docker, curl, sha256sum)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:?usage: build-library.sh <output-dir>}"
for c in docker curl sha256sum; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 2; }; done
docker info >/dev/null 2>&1 || { echo "docker unavailable" >&2; exit 2; }
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
CACHE="${DEMO_LIB_CACHE:-$OUT.cache}"   # outside OUT so Navidrome never scans it
mkdir -p "$CACHE"
IMG=navis-demo-library:1

echo "== image"
docker build -q -t "$IMG" "$HERE" >/dev/null

echo "== download and verify"
n=0
while IFS=$'\t' read -r sha url _; do
  [[ -z "$sha" || "$sha" == \#* ]] && continue
  n=$((n + 1))
  if [[ -f "$CACHE/$sha" ]] && [[ "$(sha256sum "$CACHE/$sha" | cut -d' ' -f1)" == "$sha" ]]; then continue; fi
  curl -fsSL --retry 3 -o "$CACHE/$sha.part" "$url"
  got="$(sha256sum "$CACHE/$sha.part" | cut -d' ' -f1)"
  if [[ "$got" != "$sha" ]]; then
    rm -f "$CACHE/$sha.part"
    echo "sha256 mismatch for $url: expected $sha, got $got" >&2; exit 1
  fi
  mv "$CACHE/$sha.part" "$CACHE/$sha"
  echo "  fetched $url"
done < "$HERE/manifest.tsv"
echo "  $n sources verified"

echo "== tag"
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$HERE:/work:ro" -v "$CACHE:/cache:ro" -v "$OUT:/out" \
  "$IMG" python3 -I /work/tag.py /work /cache /out
echo "done: $OUT"
