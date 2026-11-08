# Demo server for App Review

A small always-on Navidrome (Subsonic) server with a public-domain library and
one restricted reviewer account, so Apple App Review and TestFlight testers can
sign in. Public URL: `https://navis.porthorion.com/demo`. Plan and ledger:
[../plans/Demo_Server_Plan.md](../plans/Demo_Server_Plan.md).

This repo is public: hostnames, IPs, host paths and credentials live only in the
host-only `.env` and credentials file.

## Architecture

```
client -> Cloudflare -> tunnel -> proxy (NPMplus/nginx) -> 127.0.0.1:${DEMO_PORT} -> Navidrome container
```

- The proxy exposes only `/demo/rest/` (the Subsonic API Navis uses). Every
  other path under `/demo` (web UI, `/auth`, `/api`) is a 404. Navidrome's UI
  cookie is stripped.
- **The public database has no admin user.** Subsonic auth is per request, so an
  admin would be usable over `/demo/rest/`. Bootstrap therefore keeps a
  host-only **master seed** (with the admin, in `DEMO_MASTER_DIR`, mode 600,
  never mounted into the container) and derives the **public seed** (mounted at
  `/seed`) from it with the admin deleted (pinned sqlite3 container, every
  user-referencing table cleared, `VACUUM`, foreign-key and integrity checks).
  Navidrome logs "No admin user found" at start; that is expected, and
  `/auth/createAdmin` is refused while users exist.
- The proxy blocks user, password, share, radio and jukebox methods (403),
  rate-limits per client IP and disables the access log for `/demo`.
- **Nightly reset = restart.** On every start the entrypoint copies the seed
  database over the live one, so stars, playlists, play counts and queues return
  to the seeded state; the reviewer password stays the same.

## Files (`deploy/demo-server/`)

| File | Purpose |
|---|---|
| `compose.yaml` | Pinned Navidrome, hardened, bound to loopback |
| `entrypoint.sh` | Seed copy on start; refuses to start without a seed |
| `bootstrap.sh` | First setup, `rotate-reviewer` (needs `docker compose`, `curl`, `jq`, `openssl`; pulls the pinned sqlite3 image) |
| `nginx/http-zone.conf` | `limit_req_zone` for the proxy `http` context |
| `nginx/demo-location.conf` | Server-level block for the proxy host's Advanced config |
| `.env.example` | Placeholders for the host-only `.env` |
| `selftest.sh` | End-to-end check on local docker (bootstrap, nginx, reset, rotation); `DEMO_TEST_MUSIC=<dir>` also checks a built library |
| `library/` | `build-library.sh`, `manifest.tsv` (sources, sha256, tags), `lyrics/*.lrc`, `LICENSES.md`, `Dockerfile` |

## Rebuild from scratch

1. Host dirs: `data/` (empty), `seed/` and `master/` (mode 700), `music/`, all owned by the
   user that will run the container (`DEMO_UID`/`DEMO_GID`). Put the stack files
   (`compose.yaml`, `entrypoint.sh`, `bootstrap.sh`, `.env`) in one directory.
2. `cp .env.example .env`, fill in paths, a fixed `ND_PASSWORDENCRYPTIONKEY`
   (`openssl rand -hex 32`), the creds file path, `DEMO_MASTER_DIR` and the reviewer login. Keep
   `.env` mode 600.
3. Library: `deploy/demo-server/library/build-library.sh <host dir>/music` (needs only
   docker, curl, sha256sum; see `library/README.md`). Copy `library/` to the host first.
4. `./bootstrap.sh`. It starts Navidrome in bootstrap mode, creates a random
   admin (login saved to `DEMO_ADMIN_CREDS_FILE`, mode 600), creates the
   non-admin reviewer, runs a full scan, exports the master seed, derives the admin-free `seed/navidrome.db` and starts
   the stack in normal mode. Afterwards remove the reviewer password from
   `.env`. Re-running with a seed present refuses unless `DEMO_FORCE=1`.
5. Komodo (v2 API): the periphery stacks directory is root-owned, so create
   `<stacks>/<name>` with a throwaway root container
   (`docker run --rm -v <stacks>:/s alpine sh -c 'mkdir /s/<name> && chown <uid>:<gid> /s/<name>'`)
   and keep the stack files there. `CreateStack` with `files_on_host: true`,
   `run_directory: ""`, `file_paths: ["compose.yaml"]`, `env_file_path: ".env"`,
   `server_id` of the host; then `DeployStack`. `docker compose down` the
   bootstrap container first. Do not print `GetStack` output: `deployed_config`
   contains the interpolated `.env` values.
6. Komodo procedure with one stage `RestartStack`, fields `schedule_format:
   "Cron"`, `schedule: "0 0 4 * * *"` (six fields, seconds first),
   `schedule_timezone: "<host IANA zone>"`, `schedule_enabled: true`.
   `ListProcedures` reports `next_scheduled_run`; check it reads 04:00 local.
7. Proxy: append `nginx/http-zone.conf` to the proxy's `custom_nginx/http.conf`
   (root-owned, same root-container trick; already included in the `http`
   context) and set the proxy host's `advanced_config` to
   `nginx/demo-location.conf` (fix the upstream address if the proxy is not on
   the same host). Via the NPMplus API, `PUT /api/nginx/proxy-hosts/<id>` rejects
   unknown keys: send only the keys listed in the PUT schema (`GET /api/schema`),
   so drop `id`, dates, `owner_user_id` and `access_list_id`. Back up the host JSON
   and `http.conf` first; rollback is `advanced_config: ""` plus the old file.
8. Check from outside: `ping` as the reviewer works, `/demo/` is 404, no
   `Set-Cookie`, `cf-cache-status` is DYNAMIC. Reset proof: star a song and
   create a playlist, run the procedure, both lists are empty afterwards.

Validate any change to these files with `deploy/demo-server/selftest.sh`
(about two minutes; creates and removes its own containers and temp dir).

## Library

40 tracks, 6 albums (a two-disc album, a compilation, ReplayGain, synced lyrics, own covers).
**Licence policy:** CC0 1.0 or public domain for both composition and recording only; no BY, NC
or ND. Record each new track's source page, direct URL, licence and sha256 in `manifest.tsv`;
`build-library.sh` regenerates `LICENSES.md` (copy it back into the repo). To rebuild, run
`build-library.sh <dir>`: it re-downloads, verifies checksums and re-tags in place, then
rescan (restart the stack with `DEMO_FORCE=1 ./bootstrap.sh` to refresh the seed).
Local proof: `DEMO_TEST_MUSIC=<dir> deploy/demo-server/selftest.sh`.

## Rotate the reviewer password

On the host: `DEMO_REVIEWER_PASSWORD='<new>' ./bootstrap.sh rotate-reviewer`.
It runs bootstrap mode on the master seed, changes the password as admin,
re-exports the master, re-derives the public seed and restarts normally. The
same command with the unchanged password re-derives the public seed (for
example after a bootstrap change). Update App Store Connect review
notes afterwards.

## Bump the Navidrome version

1. Pick the release (`gh release list -R navidrome/navidrome`), read its notes.
2. `docker pull deluan/navidrome:<v>`; take the digest from
   `docker image inspect`. Update both in `compose.yaml`.
3. Re-verify every `ND_*` option against `conf/configuration.go` at that tag
   (options are silently ignored when misspelled or removed).
4. Run `selftest.sh`. If the schema changed, rebuild the seeds with `DEMO_FORCE=1`
   (or rotate), then redeploy the stack.

## Hardening

Pinned image; loopback bind; non-root, `cap_drop: ALL`, `no-new-privileges`,
read-only root filesystem with tmpfs `/tmp`; library mounted `:ro`; sharing,
Last.fm, ListenBrainz, Deezer and other external services, insights, plugins,
user editing, artwork upload and transcoding config off; downloads on; random
admin only in the host-only master seed (absent from the public database); reviewer non-admin; proxy allow-list of
`/demo/rest/`, blocked methods, `limit_req`; Navidrome log level `warn`;
Docker log rotation (10 MB x 3); host unattended-upgrades.

## Logs

No proxy access log for `/demo`. Navidrome logs at `warn` only; Docker keeps at
most 30 MB. Nothing is shipped elsewhere.

## Cost

Runs on an existing home server: no cost beyond power. Alternative if that is
ever not acceptable: a small VPS (about 4-5 EUR per month) with the same stack.
