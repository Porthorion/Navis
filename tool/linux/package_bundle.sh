#!/usr/bin/env bash
# Shared release.sh/remote/local packaging of the one Ubuntu-built bundle.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mode="${1:?bundle|deb|rpm|all}"; version="${2:?vX.Y.Z}"; prefix="${3:-navis}"
[[ "${mode}" =~ ^(bundle|deb|rpm|all)$ && "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "${prefix}" =~ ^navis(-dev)?$ ]] || exit 1
bundle="${repo}/build/linux/x64/release/bundle"
[[ -x "${bundle}/navis" && -f "${bundle}/lib/libapp.so" && -f "${bundle}/lib/libmpv.so.2" ]] || { echo 'Incomplete release bundle' >&2; exit 1; }
mkdir -p "${bundle}/data/licenses"
rm -f "${bundle}/data/licenses/LicenseRef-Navis.txt"
install -m 644 "${repo}/LICENSE" "${bundle}/data/licenses/GPL-3.0.txt"
install -m 644 "${repo}/assets/licenses/LGPL-2.1.txt" "${repo}/assets/licenses/libmpv-ffmpeg-NOTICE.txt" "${bundle}/data/licenses/"
# Strip ELF symbols only. libmpv stays a separate, replaceable shared library.
while IFS= read -r -d '' elf; do
  if file "${elf}" | grep -q 'ELF'; then strip --strip-unneeded "${elf}"; fi
done < <(find "${bundle}" -type f -print0)
max_glibc="$(objdump -T "${bundle}/navis" | sed -n 's/.*GLIBC_\([0-9.]*\).*/\1/p' | sort -Vu | tail -1)"
[[ -n "${max_glibc}" && "$(printf '%s\n' "${max_glibc}" 2.35 | sort -V | tail -1)" == 2.35 ]] || { echo "Unsupported GLIBC baseline: ${max_glibc}" >&2; exit 1; }
echo "navis maximum GLIBC: ${max_glibc}"
if [[ "${mode}" == bundle || "${mode}" == all ]]; then
  tar -czf "${repo}/${prefix}-${version}-linux.tar.gz" -C "${bundle}" .
fi
if [[ "${mode}" == bundle ]]; then exit 0; fi
stage="$(mktemp -d "${repo}/build/linux/package-stage.XXXXXX")"
trap 'rm -rf "${stage}"' EXIT
root="${stage}/root"
mkdir -p "${root}/opt/${prefix}" "${root}/usr/bin" "${root}/usr/share/applications" "${root}/usr/share/icons/hicolor"
cp -a "${bundle}/." "${root}/opt/${prefix}/"
printf '#!/usr/bin/env bash\nexec "/opt/%s/navis" "$@"\n' "${prefix}" > "${root}/usr/bin/${prefix}"
chmod 755 "${root}/usr/bin/${prefix}"
app_name=Navis
[[ "${prefix}" != navis-dev ]] || app_name='Navis Dev'
sed -e "s/^Name=.*/Name=${app_name}/" -e "s|^Exec=.*|Exec=/usr/bin/${prefix} %U|" -e "s/^Icon=.*/Icon=${prefix}/" \
  "${repo}/linux/packaging/com.navis.app.navis.desktop" > "${root}/usr/share/applications/${prefix}.desktop"
cp -a "${repo}/linux/packaging/icons/hicolor/." "${root}/usr/share/icons/hicolor/"
if [[ "${prefix}" != navis ]]; then
  while IFS= read -r -d '' icon; do mv "${icon}" "$(dirname "${icon}")/${prefix}.png"; done < <(find "${root}/usr/share/icons" -name navis.png -print0)
fi
desktop-file-validate "${root}/usr/share/applications/${prefix}.desktop"
mkdir -p "${root}/usr/share/doc/${prefix}"
cat > "${root}/usr/share/doc/${prefix}/copyright" <<COPYRIGHT
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Navis
Source: https://github.com/Porthorion/Navis

Files: *
Copyright: Porthorion and third-party contributors (see bundled notices)
License: GPL-3.0-or-later AND LGPL-2.1-or-later
 Full licence texts and libmpv notices are installed under
 /opt/${prefix}/data/licenses/.
COPYRIGHT
if [[ "${mode}" == deb || "${mode}" == all ]]; then
  mkdir -p "${root}/DEBIAN"
  cat > "${root}/DEBIAN/control" <<CONTROL
Package: ${prefix}
Version: ${version#v}
Section: sound
Priority: optional
Architecture: amd64
Maintainer: ${NAVIS_DEB_MAINTAINER:-Porthorion <support@porthorion.com>}
Depends: libgtk-3-0, libsecret-1-0, libpulse0, libasound2 | libasound2t64
Homepage: https://navis.porthorion.com
Description: Navis music player
 Open-source Subsonic/OpenSubsonic music player built with Flutter,
 with a replaceable LGPL libmpv.
CONTROL
  dpkg-deb --root-owner-group --build "${root}" "${repo}/${prefix}-${version}-linux-amd64.deb"
  rm -rf "${root}/DEBIAN"
fi
if [[ "${mode}" == rpm || "${mode}" == all ]]; then
  mkdir -p "${stage}/rpmbuild"
  cat > "${stage}/navis.spec" <<SPEC
Name: ${prefix}
Version: ${version#v}
Release: 1
Summary: Navis Subsonic/OpenSubsonic music player
License: GPL-3.0-or-later AND LGPL-2.1-or-later
URL: https://navis.porthorion.com
BuildArch: x86_64
Requires: gtk3, libsecret, pulseaudio-libs, alsa-lib
# Bundled libraries are private to Navis; do not expose their SONAMEs globally.
%global __provides_exclude_from ^/opt/.*$
%global __requires_exclude ^lib(app|flutter_linux_gtk|.*_plugin)\\.so.*$
%global debug_package %{nil}
%global __os_install_post %{nil}
%description
Open-source Subsonic/OpenSubsonic music player with a replaceable LGPL libmpv.
%install
mkdir -p %{buildroot}
cp -a "${root}/." "%{buildroot}/"
%files
%defattr(-,root,root,-)
/opt/${prefix}
/usr/bin/${prefix}
/usr/share/applications/${prefix}.desktop
/usr/share/doc/${prefix}/copyright
/usr/share/icons/hicolor/*/apps/${prefix}.png
SPEC
  rpmbuild --define "_topdir ${stage}/rpmbuild" --define '_build_id_links none' -bb "${stage}/navis.spec"
  cp "${stage}/rpmbuild/RPMS/x86_64/${prefix}-${version#v}-1.x86_64.rpm" "${repo}/${prefix}-${version}-linux-x86_64.rpm"
fi
