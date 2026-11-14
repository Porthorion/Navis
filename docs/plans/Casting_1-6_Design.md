# Casting (1.6) Design

**Goal:** play the Navis queue on a TV, smart speaker or receiver (UPnP/DLNA renderers and Google Cast devices) and bring it back to the phone or desktop without losing the place. Target: on par with Symfonium's casting, without Google Play Services, on all five platforms (iOS as close as the platform allows, never zero).

**Status:** feasibility research done 2026-11-14; design awaiting owner approval. It becomes phase briefs (writing-plans format) when 1.6 work starts. Tracking issue: #2.

## What "on par with Symfonium" means

Symfonium (Android only) casts to Chromecast (through the proprietary Cast SDK, so it needs Play Services), UPnP/DLNA (Kodi included), Sonos and Plex clients. No AirPlay. Its feature set, and the complaints its users raise, set the bar:

- Renderers fetch from the server directly by default; an optional **"proxy via phone"** relays the stream for VPN-only servers, split DNS and certificate problems (Chromecast ignores local DNS).
- **UPnP gapless** via `SetNextAVTransportURI`, with a per-device switch; renderers without it (for example Eversolo) can't do gapless.
- Per-renderer settings: volume step, gapless toggle, "alternative flags" for fussy renderers, prefer the downloaded or the server copy.
- Transcoding per target format; ReplayGain on cast is experimental (phone transcoding).
- Hardware volume buttons control the renderer; Sonos groups.
- Common complaints: UPnP songs played twice or skipped, playback stopping after each track, discovery failures, reconnect after the app is killed, idle Chromecasts dropping the session.

Other Subsonic clients set a low bar: Tempo and Substreamer have basic Chromecast only, Finamp none, Jellyfin's F-Droid build drops Cast. Doing casting well is a differentiator.

## Where the code stands

- **No player seam.** `NavisAudioHandler` owns a concrete just_audio `AudioPlayer` and calls it directly at ~279 sites across its 12 part files (recovery, media session, queue loading, navigation, crossfade). The media session, notification and scrobbling are fed from `_player.playbackEventStream` and `_player.position`.
- **Queue, shuffle and repeat are already Dart-side** (`_queueItems`, `navis_shuffle_order.dart`), and the platform bridges (Linux MPRIS, Windows SMTC) already consume the `NavisPlaybackHandler` contract. Android Auto browses from the database and calls handler methods.
- **Stream URLs carry the account credential:** `SubsonicApiClient.streamUrl` adds `u`, `t` (md5 of password+salt) and `s`, or legacy `p=enc:`. Handing that URL to a TV leaks a replayable credential; `navis_audio_handler_media_session.dart` already keeps the token out of system surfaces.
- Transcoding (`format`, `maxBitRate`, `timeOffset`) is supported through `activeStreamingQualityProvider`.
- **No LAN networking:** only loopback servers (diagnostics API, just_audio's internal proxy). No mDNS/SSDP package, no `CHANGE_WIFI_MULTICAST_STATE`, no `NSBonjourServices`, and macOS release entitlements lack `network.server`.
- Listen Together/Voyage (retired) synced state, not a renderer; nothing to reuse.

## Find and reuse first

- **Handler and queue:** keep `NavisAudioHandler` as the single owner of queue, shuffle, repeat, recovery, persistence and scrobbling. Casting swaps what plays the audio, not who owns the queue. A second `NavisPlaybackHandler` would duplicate ~150 KB of queue logic and is rejected.
- **Stream URLs and transcoding:** `SubsonicApiClient.streamUrl` and `activeStreamingQualityProvider`, with a cast-target format override.
- **Source order:** `PlaybackSourceResolver` (permanent download → rolling cache → stream) decides what the proxy serves.
- **System surfaces:** `RealTimeProjectionAudioHandler`, the MPRIS/SMTC bridges and the Android Auto tree follow the handler's streams unchanged.
- **Credential redaction:** `credential_redaction.dart` for logs and diagnostics of renderer traffic.
- **Recovery:** the silent self-healing policy and existing recovery paths govern reconnects.
- **Libraries (evaluate in the spike):** `dart_cast` (pure Dart, MIT, all five platforms, CASTV2 + basic DLNA) as the Cast candidate; `bonsoir` or `multicast_dns` for mDNS; UPnP control likely a thin app-owned layer on Dio (already a dependency) plus `xml` (already in the lockfile, would become a direct dependency), since no maintained Dart package covers `SetNextAVTransportURI`, GENA events and position polling. No package that wraps the proprietary Cast SDK.

## Design

**Player layer.** Introduce a narrow app-owned player interface covering the subset the handler uses (load source, play, pause, seek, stop, volume, position, playing/processing state, completion, next-source preload). `LocalNavisPlayer` wraps just_audio with behaviour unchanged; `UpnpNavisPlayer` and `CastNavisPlayer` implement it remotely. Capabilities (crossfade, EQ, ReplayGain, speed, gapless, seek) are declared per player, and the handler skips or disables what the active player lacks. This refactor lands first, alone, with no behaviour change.

**Queue model.** App-driven on Android and desktop: the handler feeds the renderer one track plus the next (UPnP `SetNextAVTransportURI` where supported, Cast queue preload). On iOS the queue is handed to the receiver as far as the protocol allows (Cast `QUEUE_LOAD`), because iOS suspends the app while it plays no local audio.

**Stream delivery.**
- **Proxy mode (default on Android and desktop):** an app-owned LAN HTTP server, bound to the active Wi-Fi interface, path-token per cast session, revoked when the session ends. It relays server streams (adding credentials itself) and serves downloaded and cached files. The account credential never leaves the device, and VPN, split-DNS and certificate problems disappear. It costs battery while casting.
- **Direct mode (iOS, and opt-in elsewhere):** the renderer fetches from the server. Uses a Navidrome API key (OpenSubsonic `apiKeyAuthentication`, Navidrome PR #6219, merged 2026-09-28) when the server advertises it; otherwise see open question 2. Downloaded-only songs can't cast in direct mode.

**Discovery.** SSDP for UPnP renderers (Android multicast lock and permission), mDNS `_googlecast._tcp` for Cast (iOS `NSBonjourServices` entries). Manual address entry as a fallback, required on iOS until Apple grants the multicast entitlement.

**Formats.** Cast devices play FLAC (to 96 kHz/24-bit), MP3, AAC, Opus, Vorbis and WAV; no ALAC. UPnP renderers advertise accepted formats through `GetProtocolInfo`. Unsupported formats are transcoded by the server; the proxy never transcodes.

**UI.** A cast button on Now Playing and the mini player, a device picker, per-device settings (gapless, compatibility flags, volume step, stream mode), and unsupported features shown as off while casting. Hardware volume keys and the notification control the renderer.

**Reliability.** Event-based track-change detection (UPnP `LastChange` subscription with polling fallback; never infer track change from `TrackURI` alone), idempotent advance so a song is never played twice or skipped, silent reconnect after network blips or app restart, and a clean hand-back to local playback at the same position.

## Platform plan

| Platform | UPnP/DLNA | Google Cast | Downloaded songs |
|---|---|---|---|
| Android | yes (multicast lock) | yes (open protocol, no Play Services) | yes, via proxy |
| Linux, Windows, macOS | yes | yes | yes, via proxy (macOS needs `network.server`) |
| iOS | manual address now; discovery once Apple grants the multicast entitlement (apply early) | yes, queue on the receiver | no in direct mode, unless the spike proves the app stays alive |

## Phases

| Phase | Scope | Effort |
|---|---|---|
| 0. Spike | `dart_cast` against a real Cast target, SSDP + AVTransport against the owner's Samsung TVs/monitor and a software renderer, iOS Bonjour discovery and background behaviour, plain-HTTP media URLs, Navidrome API key release status | 1 week |
| 1. Player layer | Interface + `LocalNavisPlayer`; no behaviour change; full check | 1–1.5 weeks |
| 2. Proxy | LAN server, session tokens, relay + local files, entitlements and permissions | 1 week |
| 3. UPnP | Discovery, control, gapless via SetNext with capability probe, events, per-device settings | 1.5–2 weeks |
| 4. Google Cast | Discovery, CASTV2 via `dart_cast` or app-owned code, queue preload / `QUEUE_LOAD` | 1.5–2 weeks |
| 5. Integration | Cast UI, notification, Android Auto, volume keys, reconnect, hand-back | 1–1.5 weeks |

Total about 7–9 weeks. UPnP comes before Cast because the owner's test hardware is UPnP-capable. A UPnP-plus-proxy release without Cast is about 4 weeks if 1.6 needs to shrink.

Risky items (phase 1 player layer, phase 2 server, phase 5 reconnect state machine) take the full lifecycle with Sonnet `high` and Opus reviews.

## Testing

- **UPnP:** owner's Samsung TVs and Odyssey OLED G9 monitor (the monitor advertised only DIAL in standby on 2026-11-14; re-scan when on), plus software renderers (gmrender-resurrect, Kodi, Rygel) on Linux or the NAS for automated runs.
- **Google Cast:** no device owned. The spike checks whether an Android TV / Google TV emulator can act as a receiver; otherwise a real device is needed (open question 1).
- Unit tests: player-layer contract tests run against both a fake remote player and `LocalNavisPlayer`; DIDL-Lite and SOAP builders against recorded renderer responses; proxy token and range-request tests.

## Out of scope for 1.6

AirPlay, Sonos groups, Plex/Kodi-specific targets, ReplayGain or crossfade while casting, casting radio stations (revisit after the spike), multi-room.

## Open questions for the owner

1. **Cast test device:** buy a used Chromecast or Google TV device, or ship Cast only if the emulator works as a receiver?
2. **Direct mode without API keys** (iOS, older Navidrome, other Subsonic servers): allow the token+salt URL with a clear warning, or offer direct mode only when the server supports API keys?
3. **Scope if 1.6 runs long:** ship UPnP + proxy first and Cast in 1.6.x, or hold casting until both are ready?
