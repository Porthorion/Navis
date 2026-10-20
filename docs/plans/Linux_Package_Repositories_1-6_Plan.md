# Linux Package Repositories (1.6) Plan

**Goal:** Debian/Ubuntu and Fedora users add a Navis apt or dnf repository once. After that, the normal system updater (`apt upgrade`, `dnf upgrade`, GNOME Software, Discover) delivers new versions. The app stops offering its own install for repo-managed systems.

**Status:** design plan. It turns into a task-level TDD plan (writing-plans format) once the owner answers the open questions below. Builds on the 1.5.1 pkexec updater in `Linux_Package_Updates_1-5-1_Plan.md`.

## Find and reuse first

- Packages: `tool/linux/build_in_container.sh` / `package_bundle.sh` (Ubuntu 22.04 container already has `dpkg-dev` and `rpm`; add `apt-utils` and `createrepo-c` there rather than a new image).
- Hosting: R2 bucket `downloads`, prefix `navis/`, public `https://downloads.porthorion.com/navis/`. Uploads go through `tool/r2_publish.sh`; add a `repo` step to it, not a new uploader.
- Channels: reuse `stable` and `dev` as repo suites, mirroring `navis/channels/<channel>/`.
- Release flow: `tool/release.sh` already calls `r2_publish.sh` after building; the repo update becomes part of that publish.
- Verification: `tool/linux/verify_packages.sh` images for the install-from-repo tests.
- In-app: the 1.5.1 install-mode detection (`update_install_mode.dart`) gains the "repo-managed" case.

## Design

**Layout on R2**
- apt: `navis/apt/dists/<stable|dev>/{InRelease,Release,Release.gpg}` plus `main/binary-{amd64,arm64}/Packages{,.gz}`, and the pool at `navis/apt/pool/main/n/navis/`.
- dnf: `navis/rpm/<stable|dev>/x86_64/` holding the rpms and `repodata/`.

Metadata is generated in the build container: `apt-ftparchive` (no reprepro state to keep) and `createrepo_c --update`. Both are regenerated from the package list on R2, so no local state is required.

**Signing**
- A new OpenPGP key for repositories, separate from the Ed25519 manifest key. It is stored next to it in `~/.config/navis/` and backed up the same way (NAS).
- apt: sign `InRelease` and `Release.gpg`.
- dnf: `rpmsign` the packages and `gpg --detach-sign` the `repomd.xml`. The repo file uses `gpgcheck=1` and `repo_gpgcheck=1`.
- Publish the public key at `navis/navis-archive-keyring.gpg` and `navis/RPM-GPG-KEY-navis`.

**Cache rule (from the 1.5.0 edge-cache lesson)**
- Package files are immutable and never re-uploaded under the same name.
- Metadata (`InRelease`, `Release*`, `Packages*`, `repodata/*`) is mutable. Upload it with `Cache-Control: no-cache` (or max-age 300) and verify with the `?verify=` bypass.
- Upload order: packages first, metadata last, so clients never see an index pointing at a missing file.

**Retention:** keep the last 3 versions per suite in the index. Older files stay on R2, unindexed, for rollback.

**Install instructions** (website + README):
- Debian/Ubuntu: download the keyring to `/etc/apt/keyrings/navis.gpg`, and add a deb822 file `/etc/apt/sources.list.d/navis.sources` with `Signed-By:`.
- Fedora: `dnf config-manager addrepo --from-repofile=https://downloads.porthorion.com/navis/navis.repo`.

**In-app**
- Detection: an `/opt/navis` install whose system has `/etc/apt/sources.list.d/navis.sources` (or `navis.list`), or `/etc/yum.repos.d/navis.repo`, is repo-managed.
- For repo-managed installs, the update dialog shows "Navis updates through your system updater" (the `packageManager` phase from 1.5.1). There is no pkexec install, which avoids fighting the system updater.
- Non-repo package installs keep the 1.5.1 pkexec path.

**AUR:** unchanged (`navis-bin` PKGBUILD).

## Testing

1. Containers (`ubuntu:22.04`, `ubuntu:24.04`, `debian:12`, `fedora:latest`):
   - Add the repo from the staging suite and install `N`.
   - Publish `N+1`; `apt update && apt upgrade` and `dnf upgrade` reach `N+1`.
   - Tampered `Packages` / `repomd.xml` (signature mismatch) is refused.
   - A wrong key is refused.
   - Metadata served stale (cache) does not break the install: old index → old package still present.
2. Host 192.168.1.156 (Ubuntu 24.04 desktop): add the staging repo. GNOME Software / `update-manager` shows the Navis update and installs it. The app shows the "system updater" message.
3. Fedora VM (same as 1.5.1 R7): GNOME Software offers the update.
4. Upgrade from a 1.5.1 pkexec-managed install: after the repo is added, the app switches to the repo message, and no duplicate package or ownership conflict appears.
5. Dev channel suite: a dev build follows `dev` only.

## Open questions for the owner

1. Should the `.deb`/`.rpm` add the repository automatically on install, the way Chrome and VS Code do? The alternative is that users add it by hand from the website. Auto-add is the common pattern and makes updates zero-effort, but it writes into `/etc` from a postinst.
2. Should the repo serve arm64 (the `.deb` arm64 asset key exists) and a dev suite from day one?
3. Do you want a `navis-archive-keyring` package for key rotation, or just the key file?
