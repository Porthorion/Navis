# App Store listing: Navis for iPhone and iPad

The text and answers to paste into App Store Connect for the iOS app. Privacy
background is in [release-ios.md](release-ios.md#app-store-privacy-answers-for-the-owner-to-confirm-in-app-store-connect).
Character limits are Apple's, and every field below fits its limit.

## App information

| Field | Value |
|---|---|
| Name (30) | `Navis` (fallbacks if taken: `Navis Music Player`, `Navis for Navidrome`) |
| Subtitle (30) | `Your music server, everywhere` |
| Primary category | Music |
| Secondary category | none |
| Content rights | Does not contain, show or access third-party content it lacks rights to: it plays the user's own library, plus metadata, artwork and lyrics from services the user leaves enabled |
| Copyright | `2026 Porthorion` |
| Price | Free, no in-app purchases |
| Support URL | `https://github.com/Porthorion/Navis/issues` |
| Marketing URL | `https://navis.porthorion.com` |
| Privacy policy URL | `https://navis.porthorion.com/privacy/app` (the page must cover iOS first, see "Before submitting") |

### Promotional text (170)

```
Stream and download your own music library from Navidrome or any Subsonic server. Gapless playback, an equalizer, synced lyrics and offline listening. No account.
```

### Keywords (100)

```
navidrome,subsonic,opensubsonic,self-hosted,music server,offline,flac,lyrics,equalizer,gapless
```

### Description (4000)

```
Navis is a fast, offline-first music player for your own music server. Connect it to Navidrome or any Subsonic or OpenSubsonic server and your whole library is on your iPhone and iPad: instant to browse, and ready to play when the network isn't.

There is no Navis account, no tracking and no cloud in between. Navis talks straight to your server.

PLAYBACK DONE RIGHT
• Gapless playback and crossfade
• Equalizer: simple, 10-band or fully parametric, with AutoEQ headphone profiles
• Speed and pitch controls
• ReplayGain volume levelling
• Synced, scrolling lyrics
• Lock Screen and Control Center controls

OFFLINE FIRST
• Download albums and playlists to keep them on the device
• A smart rolling cache keeps what you play ready for next time
• With no connection, your library stays browsable and downloads keep playing

DISCOVER MORE
• Instant Mix from any song, and Personal Radio from Home
• ListenBrainz Weekly Jams and Weekly Exploration
• Deezer new releases and "This Is" playlists, matched to songs on your server
• Internet radio stations from your server

MAKE IT YOURS
• Light, Dark and OLED themes
• Color Styles, with colours taken from the album art
• Saved Looks, corner and density options

PRIVATE BY DESIGN
Every online service has its own switch. Turn off Online services and Navis only ever talks to your server. Your sign-in stays in the iOS keychain.

Navis needs a music server you run or have an account on, such as Navidrome. It does not include music.

Navis is free and open source under the GPL.
```

### What's New (first release)

```
Navis is now on the App Store for iPhone and iPad.
```

## Screenshots

Apple needs one set per device class; the largest size is scaled down for
smaller phones.

| Set | Size (portrait) | Simulator |
|---|---|---|
| iPhone 6.9" | 1320 x 2868 | iPhone 18 Pro Max |
| iPad 13" | 2064 x 2752 | iPad Pro 13-inch (M5) |

Order (three to eight per set): Home, Now Playing, Album, Library, Lyrics,
Equalizer, Downloads, Settings › Integrations. Taken against the live server (`sub.porthorion.com`)
with a clean status bar (9:41, full battery and signal).

## App privacy

- **Tracking:** No.
- **Data collection:** "Data Not Collected". The developer runs no server and
  receives nothing; credentials stay in the keychain.
- Conservative alternative, if Apple questions the direct third-party calls:
  Usage Data › Product Interaction (listens sent to ListenBrainz, only after
  the user adds a token) and Search History (search text sent to Deezer for
  ranking). Both not linked to identity, not used for tracking, purpose App
  Functionality.

## Age rating

| Question | Answer |
|---|---|
| Violence (cartoon, realistic, graphic) | None |
| Sexual content or nudity | None |
| Profanity or crude humour | Infrequent/Mild (lyrics from LRCLIB are shown unfiltered) |
| Horror or fear themes | None |
| Alcohol, tobacco, drugs | None |
| Mature or suggestive themes | None |
| Simulated gambling, contests, loot boxes | None / No |
| Medical or wellness | No |
| Unrestricted web access | No |
| User-generated content, messaging or chat | No |
| Advertising | No |
| Parental controls, age assurance | No |

The rating Apple computes from this is expected to be 9+. If the owner prefers
4+, answer profanity "None": the music is the user's own, and the lyrics only
match it.

## App Review information

- **Sign-in required:** Yes. Demo account username and password: entered in App
  Store Connect only, never in this file.
- **Contact:** the owner's name, phone and email, entered in App Store Connect.

### Notes for the reviewer

```
Navis is a client for self-hosted music servers that speak the Subsonic/OpenSubsonic API, such as Navidrome. It contains no music; it plays the library on the user's own server.

To review:
1. On the sign-in screen, enter the Server URL https://navis.porthorion.com/demo and the demo username and password above, then tap Connect.
2. Navis syncs the demo library, then offers optional setup (Look, Listening, Queue and Downloads, Integrations). Tap Skip Setup to go straight to Integrations, which lists the optional online services; keep the defaults and continue.
3. Browse Home or Library, open an album and tap a song. Playback continues in the background and from the Lock Screen and Control Center.
4. Downloads: open an album and tap the download button. With Airplane Mode on, the library stays browsable and the downloaded album still plays.

The demo server hosts licensed, royalty-free music.

iOS may ask for local network access: users often run their server on their home network, and the app connects to it directly. It is not needed for the demo server.

Navis has no account system of its own, no in-app purchases, no ads and no analytics. Online services such as LRCLIB lyrics, Deezer artwork and ListenBrainz can each be turned off in Settings › Integrations.
```

## Before submitting

1. Update `https://navis.porthorion.com/privacy/app`: it covers only Android,
   Linux and Windows. Add iOS (and macOS): keychain sign-in, downloads kept
   out of iCloud backup, no update checks in App Store builds.
2. Confirm the demo account works and that the demo music is licensed for
   redistribution in screenshots.
3. In App Store Connect, create version 1.5.2, select the TestFlight build
   that passed device checks, fill in this page and submit.
