#!/usr/bin/env bash
# Disposable, capped package installs; never starts Navis or a GUI.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
package_dir="${NAVIS_LINUX_PACKAGE_DIR:-$repo}"
version="${1:?vX.Y.Z}"; shift
if (( $# == 0 )); then set -- ubuntu:22.04 debian:12 fedora:latest; fi
for image in "$@"; do
  echo "==> Install verification: ${image}"
  docker run --rm -i --memory=2g --memory-swap=2g --cpus=2 \
    --mount "type=bind,src=${package_dir},dst=/artifacts,readonly" \
    -e VERSION="${version}" "$image" bash -s <<'CONTAINER'
set -euo pipefail
if command -v dpkg >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # A bare image lacks GTK, so dpkg is expected to report missing dependencies.
  dpkg -i "/artifacts/navis-${VERSION}-linux-amd64.deb" || true
  apt-get -f install -y
  dpkg-query -W -f='${Package} ${Version} ${Status}\n' navis
else
  # A fresh container has no zchunk cache to reuse. Avoid slow multi-range
  # mirror requests; repository GPG verification remains enabled.
  dnf --setopt=zchunk=False install -y "/artifacts/navis-${VERSION}-linux-x86_64.rpm"
  rpm -q navis
fi
missing="$(ldd /opt/navis/navis | grep 'not found' || true)"
[[ -z "${missing}" ]] || { echo "${missing}"; exit 1; }
echo "ldd /opt/navis/navis | grep 'not found': (empty)"
# The runner loads plugins/libmpv dynamically, so check each library as well.
for library in /opt/navis/lib/*.so /opt/navis/lib/*.so.*; do
  [[ -f "${library}" ]] || continue
  # The runner has already loaded Flutter when it loads plugins. Supply the
  # sibling library directory when inspecting a plugin in isolation with ldd.
  missing="$(LD_LIBRARY_PATH=/opt/navis/lib ldd "${library}" | grep 'not found' || true)"
  [[ -z "${missing}" ]] || { echo "${library}: ${missing}"; exit 1; }
done
echo 'ldd /opt/navis/lib/*: no missing libraries'
grep -E '^(Exec|Icon)=' /usr/share/applications/navis.desktop
test -x /usr/bin/navis
test -f /usr/share/icons/hicolor/512x512/apps/navis.png
echo 'desktop launcher and 512x512 icon: OK'
# Match the updater's ownership queries as root in every installed image.
if command -v dpkg-query >/dev/null; then
  test "$(dpkg-query -S /opt/navis/navis)" = 'navis: /opt/navis/navis'
else
  owner="$(rpm -qf /opt/navis/navis)"
  test "${owner}" = "$(rpm -q navis)"
fi
echo 'package owner of /opt/navis/navis: navis'
CONTAINER
done
