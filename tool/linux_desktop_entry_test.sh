#!/usr/bin/env bash
# Assert ./tool/dev_app.sh linux-icon installs a GLib-resolvable desktop
# launcher. Uses an isolated HOME so it never touches the caller's files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() {
  echo "linux_desktop_entry_test: $*" >&2
  exit 1
}

tmp_home="$(mktemp -d "${TMPDIR:-/tmp}/navis-desktop-entry-XXXXXX")"
cleanup() {
  rm -rf "${tmp_home}"
}
trap cleanup EXIT

export HOME="${tmp_home}"
unset XDG_DATA_HOME XDG_CACHE_HOME XDG_CONFIG_HOME XDG_STATE_HOME

cd "${REPO_ROOT}"
"${SCRIPT_DIR}/dev_app.sh" linux-icon >/dev/null

launcher="${tmp_home}/.local/bin/navis"
desktop="${tmp_home}/.local/share/applications/com.navis.app.navis.desktop"

[[ -f "${desktop}" ]] || fail "desktop file was not installed: ${desktop}"
[[ -x "${launcher}" ]] || fail "launcher missing or not executable: ${launcher}"

exec_value="$(sed -n 's/^Exec=//p' "${desktop}" | head -n1)"
[[ -n "${exec_value}" ]] || fail "desktop file has no Exec key"

if [[ "${exec_value}" == navis\ * || "${exec_value}" == navis ]]; then
  fail "Exec is PATH-relative (${exec_value}); GLib 2.88+ will reject it"
fi

exec_bin="${exec_value}"
exec_bin="${exec_bin% \%U}"
exec_bin="${exec_bin% \%u}"
exec_bin="${exec_bin% \%F}"
exec_bin="${exec_bin% \%f}"
exec_bin="${exec_bin#\"}"
exec_bin="${exec_bin%\"}"
[[ "${exec_bin}" == /* ]] || fail "Exec is not an absolute path: ${exec_value}"
[[ -x "${exec_bin}" ]] || fail "Exec target is not executable: ${exec_bin}"
[[ "${exec_bin}" == "${launcher}" ]] ||
  fail "Exec target (${exec_bin}) is not the installed launcher (${launcher})"

if ! grep -q "PROJECT_ROOT=${REPO_ROOT}" "${launcher}" &&
  ! grep -q "PROJECT_ROOT='${REPO_ROOT}'" "${launcher}" &&
  ! grep -q "PROJECT_ROOT=\"${REPO_ROOT}\"" "${launcher}"; then
  fail "launcher does not pin PROJECT_ROOT to the repository"
fi
if ! grep -q 'build/linux/x64/' "${launcher}"; then
  fail "launcher does not search the Linux bundle directory"
fi
bash -n "${launcher}" || fail "launcher is not valid bash"

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "${desktop}" ||
    fail "desktop-file-validate rejected ${desktop}"
fi

if [[ "$(uname -s)" == Linux ]]; then
  python3 - "${desktop}" "${launcher}" <<'PY' || fail "GIO rejected the desktop file"
import sys

path, launcher = sys.argv[1], sys.argv[2]
try:
    import gi

    gi.require_version("GioUnix", "2.0")
    from gi.repository import GioUnix
except (ImportError, ValueError) as exc:
    print(f"linux_desktop_entry_test: skip GIO check ({exc})", file=sys.stderr)
    sys.exit(0)

app = GioUnix.DesktopAppInfo.new_from_filename(path)
if app is None:
    raise SystemExit("Gio.DesktopAppInfo.new_from_filename returned NULL")
executable = app.get_executable()
if executable != launcher:
    raise SystemExit(f"GIO executable {executable!r} != launcher {launcher!r}")
PY
fi

echo "linux_desktop_entry_test: ok"
