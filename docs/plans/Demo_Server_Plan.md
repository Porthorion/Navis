# Demo Subsonic server for App Review (plan and ledger)

Public repo: no private hostnames, IPs, host paths, usernames or credentials
here. Host-specific values live in the host-only `.env` next to the stack.

## Goal

A small always-on Navidrome at `https://navis.porthorion.com/demo` with a
CC0/public-domain library and one restricted reviewer account, so Apple App
Review and TestFlight external testers can sign in.

## Decisions (2026-11-08)

- **Path, not subdomain.** The site already goes Cloudflare → Cloudflare
  Tunnel → reverse proxy (NPMplus) → static site. A `/demo/rest/` location on
  the existing proxy host needs no DNS, TLS or tunnel change. NPMplus already
  trusts `X-Forwarded-For` from the tunnel, so rate limits see real client IPs.
- **Only `/demo/rest/` is public.** Navis uses only the Subsonic API (no
  Navidrome `/auth` or `/api`), so the web UI and native API stay unreachable
  and the admin can't sign in from outside.
- **Komodo stack, files on server**, copied from `deploy/demo-server/`.
- **Nightly reset = restart.** The container entrypoint copies a seed
  database (host only, read-only mount) over the live one on every start, so
  playlists, stars, play counts and queues go back to the seeded state, and
  the reviewer password stays the same. A Komodo scheduled procedure restarts
  the stack nightly. A fixed `ND_PASSWORDENCRYPTIONKEY` in the host `.env`
  keeps seeded passwords readable.
- **Library is not in git.** The repo holds a manifest (source URL, licence
  evidence, checksums) and a script that downloads, tags and adds ReplayGain
  tags and LRC files deterministically.
- **Apple runs deferred** (owner, 2026-11-08): `/demo` is proved on the Linux app
  now; iOS simulator and macOS runs follow when a Mac is linked.

## Hardening checklist

Pinned image; bound to 127.0.0.1; non-root, `cap_drop: ALL`,
`no-new-privileges`; library `:ro`; sharing, Last.fm, Spotify, ListenBrainz,
insights, plugins and user editing off; admin with a random name and password
kept only on the host; reviewer non-admin; proxy blocks user, password and
share methods; proxy `limit_req`; `access_log off` for `/demo`; Navidrome log
level `warn`; Docker log rotation; host unattended-upgrades (already on).

## Ledger

| Step | State | Evidence |
|---|---|---|
| Survey: routing, host, client path handling | done | the client keeps base path (`_buildMediaUri`, Dio `baseUrl`) |
| Library candidates and licences | todo | |
| Infra files and docs | todo | |
| Library built on host | done | 40 tracks, 6 albums |
| Bootstrap, seed DB, Komodo stack, reset procedure | done (2026-11-08) | stack deployed via Komodo, procedure run once by hand |
| Proxy location | done (2026-11-08) | public checks pass; proxy host backup kept on host |
| Reviews (Sonnet, Opus) | todo | |
| Linux app run against `/demo` | todo | |
| Reset verified | manual run done; first scheduled run 04:00 next day to check | stars and playlists empty after RunProcedure |
| iOS simulator and macOS runs | deferred | needs a linked Mac |
| PR into dev | todo | |
