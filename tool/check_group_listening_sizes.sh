#!/usr/bin/env bash
set -euo pipefail

max_lines=800
failed=0

check_tree() {
  local label="$1"
  local root="$2"
  local glob_pattern="$3"

  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    local count
    count="$(wc -l < "${file}" | tr -d ' ')"
    if (( count > max_lines )); then
      echo "[check] ${label} file exceeds ${max_lines} lines: ${file} (${count})" >&2
      failed=1
    fi
  done < <(find "${root}" -type f -name "${glob_pattern}" | sort)
}

check_tree "Navis group_listening" "lib/src/features/group_listening" "*.dart"

if [[ -d "../Voyage/internal/rooms" ]]; then
  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    count="$(wc -l < "${file}" | tr -d ' ')"
    if (( count > max_lines )); then
      echo "[check] Voyage authority file exceeds ${max_lines} lines: ${file} (${count})" >&2
      failed=1
    fi
  done < <(find "../Voyage/internal/rooms" -maxdepth 1 -type f -name 'authority*.go' | sort)
fi

if (( failed != 0 )); then
  echo "[check] Listen Together size guardrail: ${failed} file(s) exceed ${max_lines} lines (warning only)." >&2
else
  echo "[check] Listen Together size guardrail passed."
fi
