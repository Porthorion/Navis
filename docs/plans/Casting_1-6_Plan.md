# Casting (1.6) Plan

**Goal:** play the Navis queue on a TV, smart speaker or receiver (UPnP/DLNA renderers and Google Cast devices) and bring it back to the phone or desktop without losing the place. Target: on par with Symfonium's casting, without Google Play Services, on all five platforms (iOS as close as the platform allows, never zero).

**Status:** feasibility research done 2026-11-14; design awaiting owner approval. It becomes phase briefs (writing-plans format) when 1.6 work starts. Tracking issue: #2. Supersedes the "Chromecast / DLNA" backlog entry in `docs/project/development-plan.md`.

## What "on par with Symfonium" means

Symfonium (Android only) casts to Chromecast (through the proprietary Cast SDK, so it needs Play Services), UPnP/DLNA (Kodi included), Sonos and Plex clients. No AirPlay. Its feature set, and the complaints its users raise on its support forum, set the bar:

- Renderers fetch from the server directly by default; an optional **"proxy via phone"** relays the stream for VPN-only servers, split DNS and certificate problems (Chromecast ignores local DNS).
- **UPnP gapless** via `SetNextAVTransportURI`, with a per-device switch; renderers without it can't do gapless.
- Per-renderer settings: volume step, gapless toggle, "alternative flags" for fussy renderers, prefer the downloaded or the server copy.
- Transcoding per target format; ReplayGain on cast is experimental (phone transcoding).
- Hardware volume buttons control the renderer; Sonos groups.
- Common complaints: UPnP songs played twice or skipped, playback stopping after each track, discovery failures, reconnect after the app is killed, idle Chromecasts dropping the session.

Other Subsonic clients set a low bar (vendor claims from store pages and forums, not verified first-hand): Tempo and Substreamer have basic Chromecast only, Finamp none, Jellyfin's F-Droid build drops Cast. Doing casting well is a differentiator.

## Where the code stands

- **No player-level abstraction.** `NavisAudioHandler` (19 part files, ~18k lines) owns a concrete just_audio `AudioPlayer`. ~280 `_player.` call sites across the main file and 11 of its parts, plus ~53 `_crossfadePlayer` sites, methods typed on `AudioPlayer`, and `setEqualizer` on both decks. The only seam is `_playerFactory` / `_buildAudioPlayer`, a test hook typed to just_audio. The media session, notification and scrobbling are fed from `_player.playbackEventStream` and `_player.position`.
- **Queue, shuffle and repeat are already Dart-side** (`_queueItems`, `navis_shuffle_order.dart`), and the platform bridges (Linux MPRIS, Windows SMTC) consume the `NavisPlaybackHandler` contract. Android Auto browses from the database and calls handler methods.
- **Stream URLs carry the account credential:** `SubsonicApiClient.streamUrl` adds `u`, `t` (md5 of password+salt) and `s`, or legacy `p=enc:`. `SubsonicAuthType` has only `token` and `legacyPassword`; there is no API-key auth. Handing that URL to a TV leaks a replayable credential; `navis_audio_handler_media_session.dart` already keeps the token out of system surfaces, and `authenticateCoverArtUri` puts it in cover art URLs too.
- Transcoding (`format`, `maxBitRate` from `activeStreamingQualityProvider`; `timeOffset` gated by `supportsTranscodeOffset`) is supported.
- **No LAN networking:** only loopback servers (diagnostics API, just_audio's internal proxy). No mDNS/SSDP package, no `CHANGE_WIFI_MULTICAST_STATE`, no `NSBonjourServices`, and macOS release entitlements lack `network.server`. `NSLocalNetworkUsageDescription` already exists on iOS and macOS.
- No per-device settings store exists in `lib/src/database/tables/`.
- Listen Together/Voyage (retired) synced state, not a renderer; nothing to reuse.

## Find and reuse first

- **Handler and queue:** keep `NavisAudioHandler` as the single owner of queue, shuffle, repeat, recovery, persistence and scrobbling. Casting swaps what plays the audio, not who owns the queue. A second `NavisPlaybackHandler` would duplicate the 18k-line queue and recovery logic and is rejected.
- **Stream URLs and transcoding:** `SubsonicApiClient.streamUrl` and `activeStreamingQualityProvider`, with a cast-target format override.
- **Source order:** `PlaybackSourceResolver` (permanent download → rolling cache → stream) decides what the proxy serves.
- **Credentials:** `subsonic_auth_interceptor.dart` gains API-key auth; keys are stored through `secure_credential_store.dart`; server support is a flag next to `supportsTranscodeOffset` in `server_capabilities.dart`.
- **System surfaces:** `RealTimeProjectionAudioHandler`, the MPRIS/SMTC bridges and the Android Auto tree follow the handler's streams unchanged.
- **Network changes:** the existing `lib/src/utils/connectivity.dart` wrapper over `connectivity_plus`.
- **Logs:** `credential_redaction.dart` for renderer traffic.
- **Recovery:** the silent self-healing policy and existing recovery paths govern reconnects.
- **Libraries (evaluate in the spike):**
  - UPnP: `upnp_client` (MIT, all five platforms, 1.5.0 Sep 2026) covers SSDP discovery, AVTransport, RenderingControl, `GetProtocolInfo` and DIDL-Lite. The app-owned layer adds GENA event subscriptions and the `SetNextAVTransportURI` capability probe. `xml` becomes a direct dependency.
  - Cast: `dart_cast` (pure Dart, MIT, all five platforms) is young (0.7.x) and video-first (no audio media type), but ships CASTV2 transport and a `MediaProxy` with range requests. The spike decides between extending it and app-owned CASTV2 (TLS + protobuf + media namespace), and whether its `MediaProxy` replaces our proxy.
  - mDNS: `bonsoir` or `multicast_dns`.
  - No package that wraps the proprietary Cast SDK.

## Design

**Player layer.** Introduce a narrow app-owned player interface covering what the handler uses (load source, play, pause, seek, stop, volume, position, playing/processing state, completion, next-source preload). `LocalNavisPlayer` wraps just_audio (both decks) with behaviour unchanged; `UpnpNavisPlayer` and `CastNavisPlayer` implement it remotely. Capabilities (crossfade, EQ, ReplayGain, speed, gapless, seek) are declared per player, and the handler skips or disables what the active player lacks. This refactor lands first, alone, with no behaviour change.

**Queue model.** App-driven on Android and desktop: the handler feeds the renderer one track plus the next (UPnP `SetNextAVTransportURI` where supported, Cast queue preload). On iOS the queue is handed to the receiver as far as the protocol allows (Cast `QUEUE_LOAD`), because iOS suspends the app while it plays no local audio. UPnP has no queue on the renderer, so on iOS a UPnP cast advances only while Navis is in the foreground (current + next track otherwise); the spike measures how far background time stretches this.

**Stream delivery.**
- **Proxy mode (default on Android and desktop):** an app-owned LAN HTTP server, bound to the active Wi-Fi interface, path token per cast session, revoked when the session ends. It relays server streams (adding credentials itself), serves downloaded and cached files, and serves cover art. The account credential never leaves the device, and VPN, split-DNS and certificate problems disappear. It costs battery while casting. The same server receives UPnP GENA `NOTIFY` callbacks on its own token path. In direct mode on iOS no server runs, so UPnP state comes from polling, and only while Navis is in the foreground.
- **Keep-alive:** while casting, the app keeps a foreground media session (ongoing notification on Android, which today is `androidNotificationOngoing: false`) that reflects the remote session, so a swipe can't kill the proxy. If the process is killed anyway, a proxy-mode cast ends; on restart Navis silently reattaches to a renderer still playing a direct URL.
- **Direct mode (iOS, and opt-in elsewhere):** the renderer fetches from the server, authenticated with an OpenSubsonic API key (`apiKeyAuthentication`; Navidrome PR #6219, merged 2026-09-28, release not confirmed). Keys are bound to one Navidrome player, don't expire and don't depend on the password. The Subsonic API only uses keys: setting one is an owner-only write to the player record through Navidrome's native API, and revoking is the same write with an empty key. So Navis gets a key in one of two ways, decided in the spike: on Navidrome, Navis (logged in as the owner) creates a dedicated "Navis cast" player with a key it generates, and revokes it when casting is turned off or the server is removed; on other servers, or if the native API proves too unstable to depend on, the user pastes a key. An unknown key (error 44) drops back to proxy mode where possible, otherwise one notice asks for a new key. Without key support, see open question 2. Direct mode always plays the server copy, so it skips permanent downloads; songs available only offline can't be cast in direct mode. Cover art uses the same key-authenticated URL as the stream, since the renderer already holds that credential.

**Discovery.** SSDP for UPnP renderers (Android multicast lock and `CHANGE_WIFI_MULTICAST_STATE`), mDNS `_googlecast._tcp` for Cast (iOS `NSBonjourServices` entries). Manual address entry as a fallback, required on iOS until Apple grants the multicast entitlement.

**Formats.** Cast devices play FLAC (to 96 kHz/24-bit), MP3, AAC, Opus, Vorbis and WAV; no ALAC. UPnP renderers advertise accepted formats through `GetProtocolInfo`. Unsupported formats are transcoded by the server; the proxy never transcodes.

**Per-device settings.** A new table keyed by renderer UDN or Cast device id (gapless, compatibility flags, volume step, stream mode), added with a stepwise migration and `navis_migration_test.dart` coverage.

**UI.** A cast button on Now Playing and the mini player, a device picker, per-device settings, and unsupported features shown as off while casting. Hardware volume keys and the notification control the renderer.

**Reliability.** Event-based track-change detection (GENA `LastChange` with polling fallback; never infer a track change from `TrackURI` alone), idempotent advance so a song is never played twice or skipped, and a clean hand-back to local playback at the same position with the local volume restored.

**Failure matrix** (silent unless the user must act, per the self-healing policy):

| Event | Behaviour |
|---|---|
| Renderer unreachable or drops the session | Silent retries with backoff; after the budget, hand back to local playback paused at the same position, with one notice |
| Wi-Fi changes or the device IP changes | Rebind the proxy, re-issue the current and next URLs, resume at position; silent |
| Server unreachable mid-track (proxy) | Proxy serves cached bytes, then the existing stream-recovery path; renderer sees a stalled stream, not an error |
| Another app takes the renderer | End the cast silently, keep the queue, show the local player paused |
| Rolling-cache file evicted while served | Proxy pins served files for the session; falls back to the server stream |
| Direct-mode key unknown (error 44) | Proxy mode where possible; otherwise one notice asking for a new key |
| App killed | Proxy mode: cast ends. Direct mode: reattach on restart |

## Platform plan

| Platform | UPnP/DLNA | Google Cast | Downloaded-only songs |
|---|---|---|---|
| Android | yes (multicast lock) | yes (open protocol, no Play Services) | yes, via proxy |
| Linux, Windows, macOS | yes | yes | yes, via proxy (macOS needs `network.server`) |
| iOS | manual address now, discovery once Apple grants the multicast entitlement (apply early); queue advances only while Navis is in the foreground; credential leaves the device unless API keys are available | yes, queue on the receiver; credential leaves the device unless API keys are available | no (direct mode), unless the spike proves the app stays alive |

## Phases

| Phase | Scope | Effort |
|---|---|---|
| 0. Spike | `dart_cast` vs app-owned CASTV2 against a real Cast target; `upnp_client` + AVTransport + GENA against the owner's Samsung TVs/monitor and a software renderer; iOS Bonjour discovery and background time; plain-HTTP media URLs; Navidrome API key release status | 1 week |
| 1. Player layer | Interface + `LocalNavisPlayer` over both decks; no behaviour change; full check | 2 weeks |
| 2. Proxy and credentials | LAN server (streams, files, art, GENA callbacks), session tokens, keep-alive notification, API-key auth with secure storage, the Navidrome cast-player key flow and the paste-a-key fallback, entitlements and permissions | 2 weeks |
| 3. UPnP | Discovery, control, gapless via SetNext with capability probe, events, per-device settings table + migration | 2 weeks |
| 4. Google Cast | Discovery, CASTV2, queue preload / `QUEUE_LOAD` | 1.5–2 weeks |
| 5. Integration | Cast UI, notification, Android Auto, volume keys, failure matrix, reconnect, hand-back | 1.5 weeks |

Total about 10–10.5 weeks. UPnP comes before Cast because the owner's test hardware is UPnP-capable. A UPnP-plus-proxy release without Cast (phases 0–3 plus the UPnP part of phase 5) is about 8 weeks.

1.6 already carries Phase 18 (widgets, Live Activity), the iOS parity items I12–I20 (CarPlay, Shortcuts, background sync, share sheet) and the Linux package repositories, so casting at full scope competes for the same release (open question 3).

Risky items (phase 1 player layer, phase 2 server and credentials, phase 3 migration, phase 5 reconnect state machine) take the full lifecycle with Sonnet `high` and Opus reviews.

## Testing

- **UPnP:** owner's Samsung TVs and Odyssey OLED G9 monitor (the monitor advertised only DIAL in standby on 2026-11-14; re-scan when on), plus software renderers (gmrender-resurrect, Kodi, Rygel) on Linux or the NAS for automated runs.
- **Google Cast:** no device owned. The spike checks whether an Android TV / Google TV emulator can act as a receiver; otherwise a real device is needed (open question 1).
- Unit tests: player-layer contract tests against a fake remote player and `LocalNavisPlayer`; DIDL-Lite, SOAP and GENA handling against recorded renderer responses; proxy token, range-request and file-pinning tests; failure-matrix cases against the fake player.

## Out of scope for 1.6

AirPlay (the iOS route picker, I12, covers it separately), Sonos groups, Plex/Kodi-specific targets, ReplayGain or crossfade while casting, casting radio stations (revisit after the spike), multi-room.

## Open questions for the owner

1. **Cast test device:** buy a used Chromecast or Google TV device, or ship Cast only if the emulator works as a receiver?
2. **Direct mode without API keys** (iOS, older Navidrome, other Subsonic servers): allow the token+salt URL with a clear warning, or offer direct mode only when the server supports API keys? This decides whether iOS can cast on such servers at all. Related: may Navis create and manage a dedicated "Navis cast" player with an API key on the user's Navidrome account automatically, or should the user always create and paste the key?
3. **Scope against the rest of 1.6:** full casting (about 10 weeks) in 1.6; UPnP + proxy (about 8 weeks) in 1.6 and Cast in 1.6.x; or move other 1.6 items out?
