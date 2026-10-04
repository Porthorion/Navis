#!/usr/bin/env bash
# Sourced helper: build the masked Last.fm key defines for a Navis build.
#
# The bundled Last.fm API key is passed to `flutter` as two hex dart-defines,
# NAVIS_LASTFM_API_KEY_MASKED (key XOR pad) and NAVIS_LASTFM_API_KEY_PAD (a
# fresh random pad per build). lib/src/utils/constants.dart XORs them back at
# runtime. This keeps the plaintext key out of the binary's string table, which
# deters casual extraction. It is NOT secrecy: the app must hold the key to use
# it, and a Last.fm API key is a client identifier, not a credential (no shared
# secret is used).
#
# The defines are written to a private (mode 600) JSON file and handed to
# flutter with --dart-define-from-file, so neither the key nor the pad is on the
# scripts' own command lines. (flutter_tools reads the file and may forward the
# values to its child processes, so this is hygiene, not a guarantee.)
#
# Never echo, log or `set -x` around these functions: they handle the key.

# navis_lastfm_mask_key <key>
#   Sets NAVIS_LASTFM_API_KEY_MASKED and NAVIS_LASTFM_API_KEY_PAD (hex, not
#   exported). Returns 1 on an empty key or a failed random read.
navis_lastfm_mask_key() {
  local key="${1-}"
  NAVIS_LASTFM_API_KEY_MASKED=""
  NAVIS_LASTFM_API_KEY_PAD=""
  [[ -n "${key}" ]] || return 1

  local key_hex pad_hex
  key_hex="$(printf '%s' "${key}" | od -An -v -tx1 | tr -d ' \n')"
  pad_hex="$(od -An -v -N "${#key}" -tx1 /dev/urandom | tr -d ' \n')"
  # One pad byte per key byte (the key is ASCII, so ${#key} is its byte count).
  if [[ ${#pad_hex} -ne ${#key_hex} || ${#key_hex} -eq 0 ]]; then
    return 1
  fi

  local masked="" i
  for ((i = 0; i < ${#key_hex}; i += 2)); do
    masked+="$(printf '%02x' "$((0x${key_hex:i:2} ^ 0x${pad_hex:i:2}))")"
  done
  NAVIS_LASTFM_API_KEY_MASKED="${masked}"
  NAVIS_LASTFM_API_KEY_PAD="${pad_hex}"
}

# navis_write_lastfm_defines_file <path> <key>
#   Writes {"NAVIS_LASTFM_API_KEY_MASKED": ..., "NAVIS_LASTFM_API_KEY_PAD": ...}
#   to <path> with mode 600. Pass the file to flutter as
#   --dart-define-from-file=<path>; the caller deletes it when the build ends.
navis_write_lastfm_defines_file() {
  local path="$1" key="${2-}"
  navis_lastfm_mask_key "${key}" || {
    echo "navis: could not mask the Last.fm key (empty key or no random source)." >&2
    return 1
  }
  (
    umask 077
    printf '{"NAVIS_LASTFM_API_KEY_MASKED":"%s","NAVIS_LASTFM_API_KEY_PAD":"%s"}\n' \
      "${NAVIS_LASTFM_API_KEY_MASKED}" "${NAVIS_LASTFM_API_KEY_PAD}" >"${path}"
  )
  chmod 600 "${path}"
  NAVIS_LASTFM_API_KEY_MASKED=""
  NAVIS_LASTFM_API_KEY_PAD=""
}
