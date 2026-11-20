# Integrations and scrobbling

Besides your own server, Navis can use a few online services. Settings ›
Integrations lists each one with what it sends and to which host, a switch per
service and per feature, and a master "Online services" switch; with it off,
Navis only talks to your server. Everything is on by default.

- **Deezer** — a Same Vibes source (artist radio), Personal Radio's related-artist songs, artist top songs (Last.fm as fallback), matched to your server in
  "This Is <Artist>" using the shared weekly-playlist resolver rules; with
  neither source enabled, Top Tracks and the "This Is" card are hidden. It also
  supplies artist photos and fan counts, "Fans also like", missing albums
  (hidden when your server has its own remote catalogue for the artist), New
  Releases from the artists you play most on Home (or your library's main
  artists while you have little play history), and a Trending Now playlist of
  the chart in You Might Like and Library › Playlists, matched to your server
  like the ListenBrainz weekly playlists. A related artist, missing album or new
  release you don't have opens as a normal page loaded from your server's remote
  catalogue (such as Octo-Fiesta), with a search only when your server cannot
  provide it.
  **Rank search results by popularity** (`deezer.searchRanking`) sends what you
  type in Search to Deezer's track, artist and album search, in parallel with
  your server's search, and uses Deezer's order only to rank: the library and
  server results are reordered (popularity breaks ties inside a text-match tier)
  and the best matched hits lead the screen as Top Results (a hero card and two tiles: on All the hero and its own artist, album or top song, with a type filter the top three of that kind), never adding
  anything your library does not already return. Search waits at most 350 ms past
  your server's answer; a later Deezer answer is ignored, so results never
  reshuffle. Nothing is sent offline, while a Playlists or Radio filter is on,
  or with the switch, Deezer or Online services off. A profile that already had
  Deezer or Online services off when this arrived starts with the switch off.
- **Last.fm** — an optional Same Vibes source (chosen under **Instant Mix**
  below, offered only with a valid key), the Instant Radio fill and a
  top-songs fallback. No Last.fm scrobbling. Navis ships no Last.fm API key
  (Last.fm requires the key owner's paid plan from 1 Dec 2026): Last.fm
  features use your own key, entered and checked under **Settings >
  Integrations** (or in onboarding), and stay locked until it validates. Same
  Vibes uses Deezer by default, so a key is only needed to choose Last.fm as
  its source, for the Last.fm leg of the Instant Radio fill and for the Last.fm
  top-songs fallback. A key you entered that Last.fm rejects shows a notice and
  Same Vibes and Personal Radio fall back to Deezer or the server. Only a local
  development build with the `NAVIS_LASTFM_API_KEY` define bundles a key (and
  then hides the field; a rejected bundled key stays silent).
- **ListenBrainz** — scrobbling, likes (sent as loved) and weekly playlists,
  after its User Token validates.
- **LRCLIB** synced lyrics (server lyrics as fallback), **update checks**,
  **AutoEQ** headphone profiles, **internet radio** now-playing info and
  **artwork** your server links from other sites.

**Instant Mix** is a three-way choice at the top of the page, a radio group
like the update source: **Same Vibes (Deezer)**, the default; **Same Vibes
(Last.fm)**, shown only when Last.fm has a verified key and enabled while the
Last.fm service and `lastfm.sameVibes` are on; and **Server Mix**. The selected
option is always the resolved mode (`resolvePreferredMixMode`, used by every
caller): Deezer needs `deezer.sameVibes` and the Deezer service; a Last.fm
choice that stops being allowed (key removed, service or feature off) falls
back silently to Deezer, and Last.fm is also the fallback when Deezer is off.
With neither source allowed, or the master switch off, it is Server Mix and the
group is disabled. Storage: `legacyInstantMixEnabled` is now the mix-mode
column only (`true` is Server Mix); the Same Vibes source is the reserved entry
`sameVibes.source.lastfm` in the `disabled_integrations` JSON list, kept
by the parser and stripped from the policy like `updates.source.github`.
`SettingsRepository.setPreferredMixMode` writes both in one transaction;
choosing Server Mix keeps the remembered source. `lastfm.sameVibes` and
`deezer.sameVibes` are ordinary JSON-stored switches that only mean "Same
Vibes may call this service"; they no longer switch the mode, so scripts that
toggled `lastfm.sameVibes` to change modes must use the picker or the column.

**Same Vibes sources.** In Deezer mode a refill resolves the seed's artist
(the server artist id, else the name; `DeezerArtistResolver`, cached 30 days)
and queues `artist/{id}/radio`, mapped to your server by the same search
matching as Last.fm; it never calls Last.fm. The whole Deezer leg (lookup and
radio) runs under 6 seconds with a cancel token; Deezer's quota (error code 4,
answered as HTTP 200) or a timeout skips Deezer for that refill
(`deezer_skipped`): the server's similar songs fill, nothing retries, and the
quota pause is not extended. No artist match, an empty radio or Deezer's "no
data" is an ordinary empty result; a transport error is a transient failure
that retries. The first refill is a foreground request; later refills and the
anchor fetch yield to the user (`background`). There is no `/top` fallback.
In Last.fm mode the Last.fm call is unchanged, except that a key Last.fm
rejects (error 10 or 26) hands that fetch to the Deezer leg when Deezer is
allowed, so the mix continues. Server Mix mid-mix makes the next refill call
nothing external. The mode is read on every refill, so a source switch applies
at the next one. The diagnostics report the real source (`mixSource` in the
last refill, `selectedSongMix` `deezer|lastfm|server`).

**Personal Radio sources.** The fill order is server, then Deezer
(`deezer.radio`, on by default), then Last.fm (only while still short; the
Last.fm leg and its rejected-key rule are unchanged), then local taste. The
Deezer leg resolves the seed's artist like Same Vibes (library album titles
break a namesake tie), reads Deezer's related artists (cached 7 days), matches
their names to library artists and takes up to two library songs per artist in
relatedness order, starred first, never the seed or a song already excluded.
Songs come from the library only. It runs only when the server did not already
fill the related slots, never offline, and under a 6 second cap with a cancel
token (also cancelled with the caller's); every request is `background`. Quota
(never retried by this leg), a timeout, any failure at all, no artist match or no
related artists makes the leg add nothing, with no notice; related entries
named like the seed's artist are skipped. The batch source is `deezer` when this leg
added the first related songs.

A feature whose service needs a credential stays locked until the key or token
is verified. Subsonic/OpenSubsonic server scrobbling stays independent of
these switches. The ListenBrainz token is stored through platform secure
storage; Drift stores only non-secret status flags. The scrobble queue stores
resolved track metadata so ListenBrainz events can flush after reconnect even
if the library row changes. A rejected ListenBrainz token disables it until the
user validates a new one.

Update checks also offer a **Source** choice (Porthorion downloads, the
default, or GitHub). The host named on the entry follows the choice, and
switching raises no notice. Updates are verified the same way from either
host. The choice is disabled with a note on dev builds, which always use
downloads.porthorion.com, and hidden on Play Store and iOS installs.

See also the [external integrations policy](../decisions/2026-10-04-external-integrations-policy.md).
