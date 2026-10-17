# Integrations and scrobbling

Besides your own server, Navis can use a few online services. Settings ›
Integrations lists each one with what it sends and to which host, a switch per
service and per feature, and a master "Online services" switch; with it off,
Navis only talks to your server. Everything is on by default.

- **Deezer** — artist top songs (Last.fm as fallback), matched to your server in
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
- **Last.fm** — Same Vibes mixes (the Instant Mix mode: on is Same Vibes, off
  is your server's mix), the Instant Radio fill and a top-songs fallback. No
  Last.fm scrobbling. Release builds bundle an API key, masked at build time to
  deter casual extraction (a Last.fm API key is a client identifier, not a
  secret, and Navis uses no shared secret); builds without one show a field for
  your own key.
- **ListenBrainz** — scrobbling, likes (sent as loved) and weekly playlists,
  after its User Token validates.
- **LRCLIB** synced lyrics (server lyrics as fallback), **update checks**,
  **AutoEQ** headphone profiles, **internet radio** now-playing info and
  **artwork** your server links from other sites.

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
