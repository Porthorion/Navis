#!/usr/bin/env bash

assert_no_test_failures() {
  local log_file="$1"
  # Flutter's compact reporter overwrites progress with CR and ANSI sequences.
  if ! awk '
    BEGIN { RS = "[\r\n]" }
    {
      gsub(/\033\[[0-?]*[ -/]*[@-~]/, "")
      if ($0 ~ /^[0-9]+:[0-9]+(:[0-9]+)? [+-][0-9]+/) {
        last_progress = $0
      }
      if (/Some tests failed|One or more uncaught errors occurred shutting down/) {
        print
        failed = 1
      }
    }
    END {
      if (last_progress ~ / -0*[1-9][0-9]*:/) {
        print last_progress
        failed = 1
      }
      exit failed
    }
  ' "${log_file}" >&2; then
    echo "[check] Flutter test log failed: reported test failures or a shutdown crash. See ${log_file} for details." >&2
    return 1
  fi
}
