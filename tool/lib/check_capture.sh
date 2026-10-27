# Retain command failure before capture failure; callers retain the log directory.
run_step_capture() {
  local label="$1" log_file="$2"
  shift 2
  local start_seconds="${SECONDS}"
  echo "[check] $label"
  local -a statuses
  set +e
  "$@" 2>&1 | tee "$log_file"
  statuses=("${PIPESTATUS[@]}")
  set -e
  echo "[check] $label completed in $((SECONDS - start_seconds))s; command exit=${statuses[0]}, capture exit=${statuses[1]}; log=${log_file}"
  if [[ "${statuses[0]}" -ne 0 ]]; then
    return "${statuses[0]}"
  fi
  return "${statuses[1]}"
}
