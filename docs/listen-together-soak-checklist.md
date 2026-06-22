# Listen Together soak checklist

Manual verification for Navis + Voyage after protocol or sync changes.
Run Voyage with PostgreSQL and persistent replay enabled in production-like setups.

## Setup

- Two devices or emulators on the same Subsonic/Navidrome origin
- Navis pointed at the same Voyage server (`NAVIS_VOYAGE_SERVERS` or settings UI)
- Protocol: `voyage-sync.v3alpha1` when available (check health endpoint)

## Connection and sync

- [ ] Host creates room; follower joins by invite or room list
- [ ] Host queue seeds on create when playing (room seed)
- [ ] Disconnect follower network for ~30s; reconnect — **room position never regresses**
- [ ] Follower shows "Catching up" / amber sync pill during reconnect, then green when synced
- [ ] App kill on follower; relaunch — resume-room prompt; rejoin restores session
- [ ] Background app 5+ minutes; return — session refresh or rejoin without manual reconfigure

## Collaborative control

- [ ] Member A play/pause/seek — member B follows within ~1s on LAN
- [ ] Member B queues track — both see queue; playback unchanged if pure append
- [ ] Concurrent queue add from two members — no crash; eventual consistent queue
- [ ] Lagging member does not drag room backward after reconnect

## Remote / search3 tracks

- [ ] Host queues search3 remote track (`remote-*` id) — follower resolves via search3 and plays local copy
- [ ] Unresolvable track — auto-skip within ~2s; snackbar "not available on your library"
- [ ] Queue row shows resolution status (resolved / resolving / unavailable)

## Failure modes

- [ ] Revoked/removed member sees clear error and leaves room
- [ ] Fingerprint mismatch blocked on join with readable message
- [ ] Room close — all clients return to idle cleanly

## Server ops

- [ ] `GET /api/v1/health` lists `voyage-sync.v3alpha1`
- [ ] `GET /api/v1/ready` passes with Postgres
- [ ] Metrics: `playback_rewind_rejected_total`, `broker_soft_drops_total` observable under load

## Automated CI (run before release)

```bash
cd Voyage && go test ./...
cd Navis && flutter test test/src/features/group_listening/
```
