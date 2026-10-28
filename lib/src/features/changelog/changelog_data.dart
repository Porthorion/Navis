/// Static changelog entries for each version.
///
/// This file is the single source of truth for both the in-app changelog and
/// the Forgejo release notes (`tool/generate_release_notes.dart` imports it),
/// so it must stay plain Dart with no imports.
///
/// When work on a new version starts, add its [ChangelogVersion] at the top
/// of [changelogs] together with the `pubspec.yaml` bump (see "Versioning" in
/// `docs/development/agentic-engineering.md`). Every `x.y.0` release is a major
/// release:
/// give it 3–5 [ChangelogVersion.highlights] and, optionally, a
/// [ChangelogVersion.codename] and [ChangelogVersion.iconAsset].
class ChangelogVersion {
  const new({
    required this.version,
    required this.entries,
    this.released,
    this.codename,
    this.iconAsset,
    this.summary,
    this.highlights = const <ChangelogHighlight>[],
    this.specialThanks = const <String>[],
  });

  /// Semver string without the leading 'v' (e.g. '0.2.8').
  final String version;

  /// Bullet-point style change descriptions.
  final List<ChangelogEntry> entries;

  /// Release date as `YYYY-MM-DD`, or null when unknown or not yet released.
  final String? released;

  /// Optional name for a major release, shown as "Meet Navis 1.4 “Navi”".
  final String? codename;

  /// Optional bundled SVG or PNG under `assets/changelog/`, shown as the
  /// release's cover. It is a single-colour glyph: the UI keeps only its shape
  /// and paints it in the theme's on-accent colour on the accent colour. The
  /// UI falls back to a typographic cover when it is null or fails to load.
  final String? iconAsset;

  /// Optional one or two sentences, shown only in the changelog banner.
  final String? summary;

  /// The headline changes of a major release, shown as cards and badges.
  final List<ChangelogHighlight> highlights;

  /// People to thank for feedback or ideas that shaped this release.
  ///
  /// This is displayed in its own section after the release entries.
  final List<String> specialThanks;

  List<int>? get _parts {
    final parts = version.split('.');
    if (parts.length != 3) return null;
    final numbers = parts.map(int.tryParse).toList();
    if (numbers.any((n) => n == null)) return null;
    return numbers.cast<int>();
  }

  /// Every `x.y.0` release is a major release and gets the banner treatment.
  bool get isMajor => _parts?[2] == 0;

  /// `1.4` for a major release, the full version otherwise.
  String get displayVersion {
    final parts = _parts;
    if (parts == null || parts[2] != 0) return version;
    return '${parts[0]}.${parts[1]}';
  }

  /// The `x.y` series this release belongs to, e.g. `1.4` for `1.4.2`.
  String? get series {
    final parts = _parts;
    return parts == null ? null : '${parts[0]}.${parts[1]}';
  }

  /// [released] as a date, or null when absent or malformed.
  DateTime? get releasedDate =>
      released == null ? null : DateTime.tryParse(released!);

  int countOf(ChangelogEntryType type) =>
      entries.where((entry) => entry.type == type).length;
}

class ChangelogEntry {
  const new(this.text, {this.type = ChangelogEntryType.improvement});

  final String text;
  final ChangelogEntryType type;
}

enum ChangelogEntryType { fix, improvement, newFeature }

/// A headline change of a major release.
class ChangelogHighlight {
  const new({required this.icon, required this.title, required this.body});

  final ChangelogHighlightIcon icon;

  /// A short name, two or three words.
  final String title;

  /// One short line describing the change.
  final String body;
}

/// Icons a highlight can use. Presentation maps them to Material icons so
/// this file needs no Flutter import.
enum ChangelogHighlightIcon {
  sparkle,
  equalizer,
  speed,
  headphones,
  performance,
  search,
  library,
  sync,
  desktop,
  player,
  download,
  setup,
  audio,
  queue,
}

/// All changelogs, newest first.
const List<ChangelogVersion> changelogs = [
  ChangelogVersion(
    version: '1.5.1',
    entries: [
      ChangelogEntry(
        'Android and iOS: the in-app volume slider is gone from the player '
        'settings. Playback always runs at full app volume, so nothing can '
        'stay quietly turned down; use the volume buttons on your phone. Desktop '
        'keeps all its volume controls.',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Android: album art shows again on Bluetooth and car displays, which '
        'had shown only the title and artist since 1.4.0.',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Play during a final playback failure now resumes the same song after '
        'shutdown, while a newer seek keeps its target and a later Pause stays '
        'paused. Desktop cut recovery keeps the song and your latest seek '
        'during queue fills, queued appends or a failed reopen. Removing the '
        'cut song preserves Play/Pause for the remaining queue. Pausing a '
        'failed reload lets failover select the next song paused, and a '
        'rejected Fast Seeking bridge opens the original only once.',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'On Android, Ogg/Opus transcodes can recover a mid-song connection '
        'cut without reloading the song: Navis joins a continuation to the '
        'audio already buffered.',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Adding an album or several songs to a server playlist now works on '
        'Navidrome 0.64, which silently ignored multi-song adds. Navis '
        'verifies the result and reports songs that could not be added.',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'The next song now downloads as soon as the current one is '
        'saved, so song changes and the first seeks after them start without '
        'waiting on the network. Playback settings has a new "Prefetch the '
        'next song on mobile data" switch (on by default). Failed warms no longer '
        'delay unrelated songs, and refilling a deleted current file immediately '
        're-arms the next download; startup keeps the saved current and next cache files. '
        'Background downloads keep memory bounded on slow storage.',
      ),
      ChangelogEntry(
        'Desktop quick search keeps all its filter chips on one line.',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Keep drag-seek streams reconnectable after native probes and network cuts, '
        'and preserve preview adoption during queue navigation.',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Seeking starts sooner when you pause the thumb while dragging: '
        'eligible transcoded and Fast Seeking streams open before release. '
        'Playback keeps its place until you let go.',
      ),
      ChangelogEntry(
        'Android: Repeat All no longer restarts streamed songs just before '
        'they finish. Changing repeat mode, adding songs or removing another '
        'streamed song at the end of a song keeps playback moving. Seeking '
        'after the player pauses at a song’s end keeps the chosen position; '
        'turning Repeat Off also releases that pause. Removing the current '
        'song can still leave playback paused. Seeking or pressing Pause then '
        'Play just as a song ends can still restart it or skip to the next song.',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Android: a song queued twice no longer downloads twice or loses its '
        'cached copy. The repeat plays from the first copy, so seeking and '
        'offline playback behave the same for both. A queue release or insert '
        'with crossfade on no longer leaves its songs unregistered while the '
        'crossfade deck catches up.',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Android seeks beyond a partial download give playback bandwidth '
        'priority, close abandoned range requests and keep waiting while data '
        'arrives. Changing a seek target keeps the cache, and abandoned ranges '
        'close even while the server is silent. A larger forward buffer helps '
        'ride out brief network blips. Seek recovery clears the retired '
        'download’s caching status.',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Desktop playback retries a cut transcode at its last song position '
        'instead of treating it as the end, including Repeat One and the last '
        'song in a queue, when the server supports transcode offsets. Recovery '
        'keeps the current listening session and silences the next song while '
        'reopening, including after artwork refreshes, Play commands or audio-focus '
        'resume during recovery. Failed recovery still skips quietly or stops at '
        'the queue end, honoring the latest Play or Pause. A failed final-song '
        'reopen preserves the queue and Play retries that song where it stopped; '
        'queue edits keep their normal playback behavior.',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Desktop rolling-cache downloads of originals resume after connection '
        'cuts when the server supports byte ranges, preserving the downloaded '
        'prefix and keeping Fast Seeking available. Continuations must retain '
        'the original validator when supplied, and temporary TLS reconnect '
        'failures use the same bounded retries.',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fast Seeking on Linux and Windows plays an Opus 256 kbps stream when '
        'seeking beyond a lossless download on a slow connection. The original '
        'keeps downloading; seek back into the downloaded part or play the '
        'song again to return to lossless. Bridge failures fall back to the '
        'original stream or completed local copy, including downloads that '
        'finish during recovery. Pausing always lets the original download '
        'continue. Disable it in Playback settings.',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Play now always plays in order; Shuffle shuffles. The shuffle button '
        'still shuffles or restores the current queue at any time.',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Same Vibes and Personal Radio use Last.fm for far more songs again: '
        'when Last.fm has no similar tracks for a song, Navis now mixes from '
        'the best-known tracks of similar artists instead of falling back to '
        'the server',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Bound desktop seek waits and recover stuck positions automatically; '
        'keep slow song starts loading while data arrives, including when '
        'seeking before the first load finishes, and continue to the next song '
        'if a seek recovery cannot reload the stream. Retry slow cold seeks '
        'with a fresh source, recover silently, and keep the final stopped '
        'song available to Play again. Stop quietly instead of skipping '
        'through the queue when several songs in a row cannot play',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fix Repeat One silently rewinding streamed songs before the end '
        'on Android and stalling when the queue fills in the background',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Resume transcoded songs at the current position after a network stall '
        'or disconnect instead of replaying them or skipping to the next song, '
        'again after a later stall in the same song, and play a song you '
        'return to from its start',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fix in-app Linux updates for Debian and Fedora packages with a system '
        'authentication prompt; AUR and other package-managed installs show '
        'package-manager instructions. Automatic installation works from the '
        'first update after 1.5.1; 1.5.0 users update to 1.5.1 manually or '
        'through their package manager.',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Linux package updates now say "Installing the update. This can take '
        'a minute." while the package manager works, instead of a bare '
        '"Applying update…".',
      ),
      ChangelogEntry(
        'Show the seek bar buffered line exactly: for Opus, Vorbis and FLAC '
        'the cached part is read from the downloaded file instead of being '
        'estimated from the bitrate, and after seeking past the download the '
        'part the player has loaded is drawn on its own instead of filling '
        'the gap behind it',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Reuse the verified update download after cancelling installation or '
        'reopening the update dialog, checking the file again before retrying',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fix transcoded songs replaying after the stream finishes on Android',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Add an optional Random Albums section to Home (Settings › Appearance)',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Seeking in a transcoded song now jumps straight to the new position '
        'on servers that support it, instead of waiting for the download',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Show a clear message when relinking an unavailable song fails, '
        'instead of saying the selection is out of date',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Clearing a cache, importing manually matched downloads and matching '
        'a weekly playlist now say what they are doing while they run',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Report a failed "Check now" in About instead of staying silent',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'The seek bar now shows how much of a song is already downloaded, '
        'instead of stopping short after a seek',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.5.0',
    codename: 'Chromatic',
    iconAsset: 'assets/changelog/chromatic.svg',
    summary:
        'Make Navis look the way you want with color styles, Fine-Tune '
        'Colors and saved Looks; enjoy a Now Playing screen that fits every '
        'phone; discover more with Trending Now, New Releases and richer '
        'artist pages; and get signed updates plus a large round of playback, '
        'sync and privacy fixes.',
    highlights: [
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.sparkle,
        title: 'Your look',
        body:
            'Color styles, Fine-Tune Colors, saved Looks, corners and density',
      ),
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.player,
        title: 'Now Playing',
        body: 'New backgrounds and a layout that fits every phone',
      ),
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.search,
        title: 'More to discover',
        body: 'Trending Now, New Releases, Fans Also Like and Missing Albums',
      ),
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.download,
        title: 'Signed updates',
        body: 'Every update is checked against a signed release list',
      ),
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.queue,
        title: 'Steadier playback',
        body: 'Dozens of queue, shuffle, seeking and system-control fixes',
      ),
    ],
    entries: [
      // New
      ChangelogEntry(
        'Color Styles: Pastel, Immersive and Night restyle Light, Dark and OLED, and Neutral keeps the classic look',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Fine-Tune Colors adjusts any color style with Intensity, Brightness and Tint rulers, with Brightness and Tint set separately for Light and for Dark, and White controls turn Play, sliders and selected controls white',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Looks save your whole appearance under a name (colors, style, corners, artwork shapes and size, density and artist view), so you can switch between them in one tap from Settings › Appearance, with Undo right after',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Use OLED When Dark switches Auto to pure black whenever your device is in dark mode, and Night Schedule switches to the Night style between the times you choose',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Flat Surfaces replaces glows, gradients, shadows and blur with solid colors, and can be limited to panels and shadows, Now Playing, or text over artwork, where album titles move below the cover',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Corner Style: Pill, Soft or Square corners for cards, buttons and panels; artwork keeps its own Artwork Shape',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Now Playing Background: Art-Tinted, Artwork (a soft blur of the cover) or Plain, also used by the queue and the desktop lyrics view',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Density: Comfortable or Compact spacing for Home, track lists and library rows',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Album titles stay on one line and scroll when they are long, over a see-through shade that keeps the whole cover visible; Album Art Shade makes the shade solid for easier reading, and Use Cover Color tints it from each cover',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        "Trending Now joins You Might Like and Library › Playlists: Deezer's chart matched to your library and your server, with songs your server lacks kept in place",
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        "New Releases on Home shows the last month's releases from the artists you play most",
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        "Artist pages add Fans Also Like (related artists, yours first) and Missing Albums (releases your server lacks, playable through your server's remote catalog)",
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Settings › Integrations shows what each online service receives, lets you switch any service or feature off, or turn off Online services so Navis only talks to your server',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Updates now come from downloads.porthorion.com and are checked against a signed release list before they install; Settings › Integrations › Update checks lets you choose downloads.porthorion.com or GitHub instead, and updates are verified the same way either way',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Search finds your saved playlists and radio stations, with Playlists and Radio filters that appear when your search matches them, including offline',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        "Playlists that live only on this device can be created and edited offline, show a 2x2 mosaic of their songs' covers, and work in the queue, downloads and Android Auto",
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Edit Playlist has a Save on Server switch to move a device playlist to your server; edits made during the upload are kept, Navis tells you how many songs the server accepted, and the device copy stays if the result is unclear. Saving the queue as a playlist offers the same choice and falls back to this device when offline',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Add radio stations that stay on this device; server admins can also save them on the server and edit or delete server stations. The Radio page has a search field on phones and tablets that filters stations by name',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Downloads settings lists missing lyrics and artwork with live progress, and Backfill Now fetches them whenever a server connection is set up',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Delete all saved Looks and Speed & Pitch presets from Cache & Storage without changing your current values; unsupported playback presets can also be deleted individually',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Shortcuts: tap the cached icon on a song to download it, tap the album art on an album page to view it full size, and long-press an album title to copy it',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Linux downloads now come as .deb, .rpm and a portable archive, and work on older distributions such as Ubuntu 22.04',
        type: ChangelogEntryType.newFeature,
      ),

      // Improved
      ChangelogEntry(
        'Now Playing on phones fits every screen: controls stay within thumb reach, short phones shrink the cover instead of cutting off controls, and tall phones get a larger cover and title. Dragging it open or closed is smoother and it covers the navigation bar as it rises',
      ),
      ChangelogEntry(
        'Buttons use one consistent accent: Play is the same solid color everywhere, secondary buttons and selected tabs share one softer shade, and toggles that are off are outlined',
      ),
      ChangelogEntry(
        'Titles, headings, buttons and menu items, including Android notification titles and channel names, now use Title Case across the app; notification text stays sentence case',
      ),
      ChangelogEntry(
        'Appearance is grouped into Theme, Color, Shape & Layout and Now Playing; Color Scheme is now Accent Color, its swatches preview your style, and custom accent colors have more accurate names',
      ),
      ChangelogEntry(
        'Setup shows the new appearance options and Integrations, new options are marked New after an update until you have seen them, and Home invites you to try them',
      ),
      ChangelogEntry(
        'After you change a Look or a Speed & Pitch preset, its picker shows the preset’s name with a * (like the equalizer), Discard puts the preset back, long names wrap instead of being cut off, and Update keeps working after you leave the page or restart',
      ),
      ChangelogEntry(
        'Home on phones has a slimmer header, so more of You Might Like fits on screen; You Might Like now prefers albums with at least three songs, keeps the same height whatever language the titles are in, and scrolls both ways right after opening the app',
      ),
      ChangelogEntry(
        'Update, offline and other notices share a calmer new look that follows your color style',
      ),
      ChangelogEntry(
        'The offline banner has a Retry button, no longer covers the status bar, and uses shorter wording; dismissing it, or three failed retries, shrinks it into a slim Offline strip that stays until the server is back, and tapping the strip brings the banner back',
      ),
      ChangelogEntry(
        'Navis checks for app updates when you open it or come back to it, at most once an hour, and pulling down to refresh Home or Library checks too; a found update stays on Home until you install or dismiss it, and a dismissed update stays hidden until a different one is available (you can still find it in About)',
      ),
      ChangelogEntry(
        'Navis refreshes its connection and library when you return to it, and opening it during a background library sync takes the sync over at once and continues from where it stopped',
      ),
      ChangelogEntry(
        'Your playlists appear before weekly mixes and other server playlists, under section headings, and playlists can be filtered by name',
      ),
      ChangelogEntry(
        'Clearing data when you sign out now says that playlists and radio stations saved on this device are removed too',
      ),
      ChangelogEntry(
        'Album Queue applies to every song list, including Trending Now, playlists, downloads and Home lists; with it off, tapping a song plays just that song',
      ),
      ChangelogEntry(
        'Opening the queue centers it on the song that is playing, and the Now Playing menu and Settings › Playback no longer repeat the Equalizer and Speed & Pitch entries already in the player controls',
      ),
      ChangelogEntry(
        'Normal crossfade blends a repeating song into its fresh start with Repeat One; Smart keeps the native loop',
      ),
      ChangelogEntry(
        'Renamed “Prefer Downloaded or Cached Audio” to “Play Cached Copies at Any Quality” to explain what it does',
      ),
      ChangelogEntry(
        'Downloads are more dependable: they check free space first and pause instead of failing when storage runs out, wait for a connection before retrying, stop retrying songs the server cannot provide, detect a download cut short and retry it, and say why a download failed. Large selections start more smoothly',
      ),
      ChangelogEntry(
        'Downloaded songs get their lyrics and artwork back reliably: the backfill follows your download network setting instead of always requiring Wi-Fi, paces LRCLIB requests and resumes after cooldowns with a live countdown while artwork keeps downloading, retries at startup, on resume, after library sync and when the connection returns, and skips recent misses; downloaded albums can recover missing server covers from a confident Deezer match when its artwork integration is on',
      ),
      ChangelogEntry(
        'Lyrics prefer your server, with LRCLIB used to upgrade to synced lyrics and failed upgrades retried after a week; opening server lyrics saves them for downloaded songs, and a temporary lookup failure no longer delays retries for a week',
      ),
      ChangelogEntry(
        'Artist pages show every release your server offers, the artist’s Deezer photo when your server has none, and the Deezer fan count; remote artists and albums open on a loading page and fill in as details arrive, instead of showing Not Found',
      ),
      ChangelogEntry(
        'Top Tracks come from Deezer, topped up from Last.fm, appear sooner and prefer copies in your library; songs your server lacks are marked Not on Server',
      ),
      ChangelogEntry(
        'Same Vibes starts from the song you chose, Server Mix works from remote songs with a library copy, and recommendations are remembered for a day to reduce online requests',
      ),
      ChangelogEntry(
        'ListenBrainz scrobbling, likes and weekly playlists each have their own switch, and Settings › Configuration is now Server Information',
      ),
      ChangelogEntry(
        'After updating, Navis rebuilds its library cache once from your server; downloads, sign-in, settings, listening history, your queue and playlists on this device are kept',
      ),
      ChangelogEntry(
        'Windows uses a Navis-built playback engine with complete corresponding source provided alongside the download, and Linux playback and the equalizer work without installing a separate audio library',
      ),
      ChangelogEntry(
        'Android downloads are now available per device architecture, and updates choose the matching APK automatically',
      ),
      ChangelogEntry(
        "Desktop library data moves out of Documents into Navis's app data folder, and Android keeps Navis data out of system backups",
      ),
      ChangelogEntry(
        'About links to the Navis website, source code, bug reports, support, privacy policy and licence, and lists complete third-party licence notices',
      ),
      ChangelogEntry(
        'Navis is open source under the GNU GPL v3.0 or later; the source code and bug reports live on GitHub',
      ),

      // Fixed: playback and queue
      ChangelogEntry(
        'Turning shuffle on mid-queue puts the current song first and shuffles every other song, including played songs, without restarting playback; turning it off restores the original order. Shuffled queues get a fresh order on repeat or restart and avoid starting with the song that just finished, and the song shown always matches the song playing',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Reset Defaults on the Playback settings page now resets only playback settings; appearance, Looks, downloads and service connections are left alone, and saving Playback settings keeps newer appearance, Look and Home section choices',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Brief connection checks no longer falsely report offline at launch or resume, and dismissed offline notices stay dismissed until recovery',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Dozens of queue fixes: Previous and Next at the ends of the queue, selections with missing library entries, cancelled or slow queue restores, restored queues honoring Previous and newer selections, and the Queue page while a new queue loads. The first song no longer repeats or stalls when it ends while the rest of the queue is loading',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Play starts reliably: repeated Play requests start music, Pause and Stop stay in effect while personal radio is still preparing, Play recovers when a large saved queue is unavailable, and playback and radio resume by themselves when the network or audio returns',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Navis no longer gets stuck on Preparing Playback after being idle; if starting takes too long, you can restart it from the same screen',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Now Playing, the mini player and the notification switch to the song you picked straight away instead of showing the previous song while it loads, and Now Playing on phones keeps its progress moving after a seek or a skip, including with Repeat One on',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Seeking in a song that is still streaming no longer restarts it, sticks or stops playback, and the song keeps caching afterwards; skipping to a remote song that your server is still fetching plays it instead of jumping past it',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Crossfade blends locally available songs on mobile data too, respects ReplayGain and volume changes, keeps mute and ducking, keeps the current song playing if the next one cannot fade in, and falls back to normal playback if it stalls',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Completed downloads always play before streaming and keep their offline status, and finished streams reliably join the rolling cache',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Playback stays paused after a phone call or audio interruption, the player shows Play once the queue has finished, and playback works after signing out and back in without restarting Navis',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Notification, Bluetooth and car controls keep working after Android restarts the media service, and system media controls keep the right position, queue edits and Next state; Linux media controls send one update per seek',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Instant Radio, Same Vibes and Server Mix restart cleanly and stop refilling after repeated failures; skipping quickly through Personal Radio no longer runs out of songs, and starting it no longer freezes briefly or leaves memory use high',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        "Internet radio keeps the station name until a song title arrives, shows live titles on desktop, never shows the previous station's song, keeps its metadata when a song selection fails, and no longer freezes Windows with station artwork. A station that fails to start restores your previous queue paused, including large queues, and shows one notice. Radio artist links stay on one line on phone Now Playing",
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Now Playing on phones never turns into a scrolling page, so swiping down always closes it, including with Arabic or Japanese titles; fullscreen lyrics follow the song that is playing and have a centered title',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Instrumental tracks show “Instrumental” instead of missing lyrics and are never retried by the lyrics backfill',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Brief freezes are gone: on Home after syncing a large library, when starting or skipping tracks, and during long Instant Radio and Server Mix sessions, where memory use also no longer grows. Album art on screen loads first, switching to the Artwork background no longer stutters, and pull to refresh no longer leaves a spinner on screen',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'On Android, skipping songs on a slow connection no longer leaves earlier songs downloading in the background',
        type: ChangelogEntryType.fix,
      ),

      // Fixed: library, playlists and sync
      ChangelogEntry(
        'First setup no longer stops on albums with incomplete server details or runs a second full sync, and those albums no longer hold up later syncs; Sync settings show how many albums are still waiting for their track lists and when the library was last checked',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library checks are more reliable: they look further back after big additions, continue while playback is paused, wait for network limits or a busy database without reporting a failure, never run twice at once, rebuild their progress after an interrupted large sync, and recover cleanly after a server change',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Android background sync follows the same freshness rules as foreground sync, waits while music is playing, stays visible after a quick pause and resume, and no longer repeats its battery tip every time you open Navis after you choose Later',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library repairs keep downloads, cached audio and queue entries intact, and missing album and artist artwork refreshes once. High memory use and possible crashes while syncing large libraries on phones with less memory are fixed',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Likes, ratings and playlists refresh right after saving, and Home sections added in an update appear even if you reordered yours; showing the last hidden Home section no longer brings the default hidden sections back',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Matching is more accurate for Japanese and other non-Latin titles, language editions, featured credits, accents and punctuation in artist names',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'A cover that timed out while loading is tried again instead of staying blank, a playlist saved to the server no longer keeps the Navidrome placeholder cover, and playlist and weekly recommendation rows show album artwork instead of the track number',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Device playlists and radio stations no longer briefly disappear from Library and Search while the lists reload',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Playlists you cannot edit no longer offer rename, delete, reorder or remove, and no longer appear in Add to Playlist; renaming, deleting, reordering, or adding to a playlist now tells you when it fails, and a radio station that fails to save shows the error inside the editor and keeps your input',
        type: ChangelogEntryType.fix,
      ),

      // Fixed: downloads
      ChangelogEntry(
        'Custom download folders are handled safely: downloads wait in the queue when the folder is missing or inaccessible, with clear actions to choose a folder or use app storage, and cancelling folder selection keeps your previous location. On Android the folder is no longer forgotten after an update or restart (if yours shows as unavailable, choose it once more) and is checked for usability even when its access cannot be made permanent. A full folder stays paused instead of repeatedly downloading the same song, and Use App Storage recovers your downloads when the folder is unset, missing or inaccessible',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Finished downloads survive an interrupted save, complete gzip-compressed downloads are no longer retried as truncated, downloads in temporarily inaccessible subfolders keep their offline records until access returns, and only temporary files Navis recorded are cleaned up in custom folders. Signing out waits for download recovery, and the storage-full notice clears when the last queued download is cancelled',
        type: ChangelogEntryType.fix,
      ),

      // Fixed: accounts, updates, privacy and security
      ChangelogEntry(
        'Sign-in and playback no longer get stuck, and Navis no longer shows the login screen for a signed-in profile, when secure storage is briefly unavailable; Navis also no longer signs you out after sitting in the background for a long time, and queued ListenBrainz listens are kept',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'ListenBrainz connection errors now explain whether a token was rejected, online services are off, requests are limited, or ListenBrainz is temporarily unavailable; outages keep your token and queued listens. Typing your ListenBrainz token during setup works on phones',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'A damaged update download is discarded with a clear message, Windows updates roll back if copying fails, and desktop updates use private temporary folders',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Server credentials stay out of cover caches and the library on this device, and every sign-out clears the caches and disconnects ListenBrainz',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Login uses legacy authentication only when the server requires it, and Settings › Server reminds you when a connection is not using HTTPS',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Radio streams and links from servers and integrations open only valid HTTP or HTTPS addresses, and radio stream URLs stay private',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Artwork downloads have size and memory limits, and downloads safely handle malformed server filenames',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'ListenBrainz, Deezer and lyrics requests wait and retry politely when a service is busy, and Contact Support opens your email app on Android',
        type: ChangelogEntryType.fix,
      ),
    ],
    specialThanks: ['To Tas for the theming and color suggestions.'],
  ),
  ChangelogVersion(
    version: '1.4.2',
    released: '2026-10-03',
    entries: [
      ChangelogEntry(
        'Seeking while a song loads keeps your latest position and preserves Play or Pause; stalled seeks recover without losing the queue',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'The compact Mini Player previews seeking while you drag and jumps once when you release',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Browsing lyrics with a mouse wheel or trackpad pauses following until you finish scrolling',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.4.1',
    released: '2026-10-03',
    entries: [
      ChangelogEntry(
        'Choose a download quality once: your next download asks whether to always use that quality, and Downloads settings let you pick Ask every time, Original, or a bitrate',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Downloads can be converted to MP3, AAC or Opus at 96 to 320 kbps, and liked songs downloaded automatically on Wi-Fi follow your saved quality',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Up to four songs download at once (two by default, one on mobile data), and the download queue can be paused and resumed',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Downloaded songs keep their cover art, so covers show offline, on the lock screen and over Bluetooth or Android Auto',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Speed & Pitch is calmer: the rulers sit flat without a glow, a line marks 1.00× and zero pitch, − and + sit at the ends of the ruler they move, numbers no longer shift while you drag, and Reset appears beside Pitch only once you change it (the 1× chip resets speed)',
      ),
      ChangelogEntry(
        'Turning off the custom download folder now asks first and explains that its files stay where they are',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Cancelling a download that is in progress now stops it, instead of the song finishing and being saved anyway',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Failed downloads now wait before retrying, songs already downloaded in original quality are no longer downloaded again, and converted downloads show their progress',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Turning off, changing or choosing your custom download folder again no longer moves or renames the files already in it: they stay where they are, and choosing that folder again picks them back up as downloads',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        "On Android, if you chose a custom download folder in a version before 1.2.8, updating no longer moves the downloads in it into Navis's own storage: they stay in that folder, and choosing it again lets Navis pick them back up",
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Changing a playback setting no longer forgets your ListenBrainz account name, turns Background Sync Only on Unmetered Networks back on, or resets the desktop volume Navis restores at launch',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Changing another setting or the desktop volume no longer restarts loading your weekly ListenBrainz playlists, so Weekly Jams and Weekly Exploration stay put in Playlists',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Bluetooth car stereos and Android Auto show cover art again after a track change, instead of staying blank for songs whose cover had not been downloaded yet',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'On phones, the volume level in the Now Playing menu no longer wraps onto two lines with larger text sizes',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Appearance shape settings now apply everywhere: Cover Art Shape also shapes song lists, the queue, the mini player and player bar, playlists and downloads, Now Playing Art Shape shapes the Now Playing cover again, and Artist Card Shape applies to artist lists and similar artists. Small covers follow the shape too, with corners scaled to their size',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Choosing a custom download folder now finishes setting it up, shows the folder as on and lists files for Manual Matching even if you switch Downloads tabs while Navis scans it',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'The Custom Folder settings (Rescan, Manual Matching and the number of songs left to match) can now be translated',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Play and Shuffle on a ListenBrainz weekly playlist now include its songs that are only available remotely',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'With Album Queue on, tapping a song in a weekly playlist plays the playlist from that song, like an album',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Weekly playlists recheck your library after every sync and search the server again once a day, so a song that was only available remotely switches to your own copy once its album is added',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Weekly playlist songs that were removed from your server no longer show as available, and pulling to refresh Home no longer makes the weekly playlists match twice',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.4.0',
    released: '2026-10-02',
    codename: 'Navi',
    iconAsset: 'assets/changelog/navi.svg',
    highlights: [
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.equalizer,
        title: 'Equalizer',
        body:
            'Drag bands on a live graph, or build 10-band and advanced filters',
      ),
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.headphones,
        title: 'AutoEQ',
        body: 'Import a correction profile for your headphones',
      ),
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.speed,
        title: 'Speed and pitch',
        body: 'Precise speeds, independent pitch, Pitch Lock and presets',
      ),
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.performance,
        title: 'Built for big libraries',
        body: 'Huge queues start instantly and browsing stays smooth',
      ),
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.search,
        title: 'Search every script',
        body: 'Arabic, Japanese, Chinese and accented titles are found',
      ),
    ],
    entries: [
      ChangelogEntry(
        'Shuffling a large artist with crossfade on no longer plays a different song than the one shown, the queue no longer collapses to one song when a stream stalls (even while a long queue is still loading), and a song whose crossfade could not be prepared fades normally again the next time it plays',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Playback and the library no longer freeze when queued songs are matched to your library while an artist or album loads',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Downloaded songs in a custom Android folder now play when Android Auto starts Navis before the phone screen is opened',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Seeking from the Windows media controls lands at the chosen position instead of jumping to the end of the song',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'A song your server could not send is no longer cached as broken audio that keeps failing until the cache is cleared, and such entries left by earlier versions are removed',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Repair Library no longer keeps failing for up to a day when albums are added to the server while it runs',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'When a song fails to stream on desktop, Navis no longer writes your server sign-in details to the terminal or system log',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'The Equalizer page no longer cuts off the preamp level or fixed values in mid-sized desktop windows',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'On desktop, the sidebar no longer shows a Library section such as Radio as selected while you are on an album or artist page',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Right after signing in, Navis no longer shows "Server unreachable. Retrying every 30s." for up to half a minute while it is still connecting',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'When Navis asks you to sign in again to the same server, the server address and username are already filled in',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Counts read naturally across the app: "1 album", "1 track" and "Every minute" instead of "1 albums" or "artist(s)", large numbers are grouped (63,733), and Sync Settings describes internal library-update details in plain words',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        "When first-time library setup cannot finish, the screen now says so once, in setup wording, and shows the server's own explanation when it gives one",
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'On desktop, notices such as "Your library is ready" now appear above the player bar instead of covering page titles and buttons',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Pages that cannot load something from your server, such as Radio on a server without internet radio, now show why straight away instead of loading for about 40 seconds and asking the server again ten times',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Your server sign-in details are no longer shared with other apps through the media controls: the lock screen, notification, Android Auto, Linux media controls and Windows media overlay now get cover art from Navis itself instead of a server address that included your token',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        "On Linux and Windows, Navis now checks your server's HTTPS certificate before streaming, so your sign-in details in the stream address cannot be read by someone intercepting the connection",
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'On desktop, a song that fails to stream is no longer handed to yt-dlp when it is installed, so your server sign-in details are not passed to another program or sent to your server a second time',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Navis is built on the latest Flutter hotfix and updated navigation, artwork, storage, database and Windows components, with their reliability and security fixes',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        "Desktop now has Back and Forward: buttons at the top of the sidebar, Alt+Left/Right (Cmd+[ and Cmd+] on macOS) and the mouse side buttons. They remember each tab's pages, work from the moment Navis opens, and never jump you to a different tab's copy of a page",
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Library remembers the section you were on (Albums, Liked, Artists, Playlists or Radio) when you come back to it, and on smaller desktop windows or icon-only sidebars the sections appear as tabs at the top of Library so they are always one click away',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Switching to Mini Player and back no longer resets your open pages, and clicking the album or artist in Mini Player returns to the full window to show it',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Back and Escape now close things in the same order everywhere: quick search, then the queue, then lyrics or Now Playing panels, then the page. On phones, Back closes lyrics before the player, and menus left open in a tab close when you switch tabs',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'The desktop lyrics view now closes when you navigate, press Escape or playback stops, instead of covering the next page',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Back buttons on Settings pages, albums, the changelog and other pages return to where you opened them from, and \u201cBack to Library\u201d on a missing album or playlist no longer leaves that page behind in the tab you came from',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        '16:9 tablets now use the full navigation rail with Library sections instead of the compact car-style rail',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Search only raises the keyboard when you tap Search again or press Ctrl+K; tapping the current tab again scrolls Home, Library, Search and Settings back to the top, and the selected tab shows a filled icon',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'On iPhone and iPad, swiping from the left edge goes back from detail pages',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        "Genre tags are no longer tracked: editing only an album's genre on your server no longer makes Navis re-sync that album, and leftover genre data is cleared from the device",
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Sync Settings now always shows when the next automatic check is due, in your local time, instead of Scheduling…, after a check that stopped at its safe sync limit or after a library repair',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'The equalizer is now available on Windows, and Windows playback runs on a current mpv and FFmpeg instead of a 2023 build',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'The update check no longer offers repository releases that are not Navis versions as updates',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Artist top tracks and ListenBrainz playlists on Home find their songs in large libraries more than twice as fast, with the same matches as before',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'After a server rebuilds its library, downloads from the rebuilt albums are linked to the new songs in the same sync, instead of only on the next full sync',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'After a server rebuilds its library, songs and artists it still has are no longer hidden until the next full sync when you had downloads from the rebuilt albums',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Very long queues stay light: songs you have played are released from the player after a while and come back when you go back to them, and jumping far ahead or back in a long queue loads only the songs around the one you picked (if it cannot load, the song that was playing continues)',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Shuffle is now handled by Navis on every platform: the Queue shows the order songs will really play in, the song shown as playing on desktop always matches what you hear, long shuffled queues start as quickly as unshuffled ones, and a shuffled queue survives restarts in the same order; turning shuffle off returns to the original order, including songs added meanwhile',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Songs from an artist queue that turn out to be unplayable only when the player reaches them now stay visible in the Queue as unavailable rows, instead of silently disappearing',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'On desktop, seeking in a streamed song that had finished caching no longer empties the rest of the queue; playback continues from the cached file with every queued song kept',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Downloads interrupted by closing Navis now resume when you open it again, instead of waiting until you next use a download control',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'A download interrupted by a crash, power loss or closing the app no longer leaves a half-written song under its real name in your Downloads folder; unfinished downloads use a temporary name that Navis removes on the next start, and the retried download keeps the normal file name',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Signing out and removing local data, or switching servers, no longer deletes music files from your own Downloads folder; only files Navis keeps in its private storage are removed',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Downloads kept in a folder reached through a link, junction or mapped drive are recognised on rescan and are no longer renamed or deleted at startup, and a Downloads folder shared between Windows and other systems keeps its matches',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'EQ import reads presets from Equalizer APO, REW, EasyEffects and AutoEQ GraphicEQ as well as ParametricEQ, FixedBandEQ and Navis files, whatever text encoding or decimal separator they use; the preview explains anything it could not reproduce, and errors name the line to fix',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Setup shows a clear message when ListenBrainz or Last.fm validation fails instead of a technical error, and Home dates, track counts and weekly playlist names follow your language',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'On desktop, album and artist shelves and the You Might Like cover strip can be scrolled by dragging with the mouse',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Resizing the window or rotating your phone no longer interrupts a swipe in You Might Like or rebuilds the carousel on every frame',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'The changelog now reads like an album page: each major release has its own cover, name and highlights, changes are grouped into New, Improved and Fixed tabs, long fix lists fold away, and earlier releases are listed below (beside it on desktop). After an update, Home shows a compact “Check out” row with the release’s cover and highlights',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Shuffling or playing an artist with many remote albums no longer slows the app down: each newly loaded release joins the queue in one step, the Queue opens straight away while releases load, and long queues hand only the next few dozen songs to the player at a time, so starting, skipping and editing them stays instant',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Choosing a custom Downloads folder no longer freezes the app on Android: the folder is scanned in the background, your existing files are adopted as they are without being rewritten, and files with Arabic, Japanese, Chinese or accented names are now recognised',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Songs added, removed or reordered while a queue is still loading are no longer lost, and adding songs before the one that is playing no longer records it twice in play history or scrobbles it twice',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Reopening Navis on Android brings back your saved queue in Queue and Now Playing straight away, paused where you left it, instead of showing an empty queue until you press Play. If Navis starts offline or before you are signed in, the queue comes back as soon as it can play',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Queue edits made just before skipping are saved, songs later in a long queue stay queued while you are offline or signed out instead of disappearing, and artist tracks that fail to join the queue stay visible as unavailable',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Files adopted from a custom Downloads folder keep their names and folders after a restart, a finished download is kept even when its folder record cannot be written, typing on other tabs no longer sets a hidden Library filter, and Equalizer values accept a comma as the decimal separator',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Artist pages open faster on large libraries and stay smooth while their releases load',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Full-screen library setup and rebuilds now start fresh every time: after Cancel and sign out, signing in again no longer stays stuck on "Cancelling and signing out", signing in again after removing data sets the library up again, and a second Repair Library or cache reset in the same session actually runs instead of returning straight to Home. If signing out from setup fails, the screen offers Retry instead of staying on "Cancelling"',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Signing in again after an interrupted first library setup no longer leaves the full-screen setup retrying forever: Retry now rescans the whole library, so setup finishes, or opens Home with any albums the server reports incompletely continuing in the background',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Choosing a speed chip, preset or Reset now sweeps the speed and pitch rulers with haptic ticks every time; previously only the first choice animated with ticks',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'At speeds other than 1.00×, Bluetooth, car and headphone displays, the lock screen, notification and Android Auto now show real listening time, so a 3:00 song at 1.50× shows 2:00 and the elapsed time stays in step; seeking from them lands where you expect. Linux and Windows desktop media controls now follow speed changes made in the app',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Local search now finds Arabic, Japanese, Chinese and accented titles, artists and albums (for example "beyonce" finds Beyoncé), and searching only punctuation no longer shows unrelated songs. Offline and on-device search results appear in a fraction of the time on large libraries',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Large queues start instantly and finish loading in seconds: shuffling a big artist, playing thousands of liked or downloaded songs, or reopening the app with a long saved queue no longer stalls the queue, and a long saved queue is never discarded at startup',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Navis is lighter and smoother with big libraries: less CPU while music plays, lower memory while browsing albums and downloads, fewer database stalls during sync and queue changes, and lyrics, mini players and download progress update without redrawing the whole screen',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Artist Play and Shuffle start available tracks immediately while all releases, including remote and featured albums, fill the queue in the background; Add to Queue also fills progressively, and unavailable tracks remain visible',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'EQ now centers on an interactive graph with draggable bands, Q and preamp controls, precise inline input, grouped Undo, and live preview. Named drafts survive preset/mode changes and restarts, with explicit save/discard and protected Advanced work. Added a dedicated Equalizer on Android and Linux with Simple, 10-band and Advanced filters, live response, automatic headroom, exact local presets and import/export; other audio backends show their availability limits',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'The Equalizer page is easier to read and edit on phones, tablets and desktops: the selected band has its own shaded curve and numbered handle, dense profiles stay legible, a band strip reaches every filter, and frequency, gain and Q each appear once with clear units, Fixed markers and exact entry. Dragging shows live values above your finger, the mouse wheel adjusts Q, preamp has a single control, draft status sits beside the preset name, and landscape phones place the controls beside the graph',
      ),
      ChangelogEntry(
        'Find headphone profiles in the offline AutoEQ catalogue, preview parametric or fixed-band imports, and keep original source settings with saved presets',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Replaced the experimental EQ and loudness booster; existing experimental settings reset to disabled and flat with a one-time notice, while named presets survive Playback Settings reset',
      ),
      ChangelogEntry(
        'Fixed oversized mobile song rows in Liked, albums and playlists; duration stays with track details and Download and More remain beside the track when space allows',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Playback speed now uses readable multipliers such as 1.00×, with smooth rulers, precise 0.01 steps, exact decimal entry, 0.10 speed buttons and clear supported limits in Playback Settings and Now Playing',
      ),
      ChangelogEntry(
        'Added independent pitch control on Android and desktop media-kit playback; pitch remains unavailable with the default Apple playback backend',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Added Pitch Lock for natural, record-player-style pitch changes as speed changes; turning it off keeps the exact current pitch, and existing precise settings and presets retain their sound until edited',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Save, update, rename and delete local speed and pitch presets, including their pitch lock mode, from Playback Settings or Now Playing; the built-in Normal preset restores 1.00× speed, zero pitch and an unlocked pitch control',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Speed and pitch adjustments stay active across queue changes, playback recovery, crossfades and app restarts, with limits and feedback based on what the active audio backend supports',
      ),
      ChangelogEntry(
        'Speed & Pitch and the Equalizer are one tap away in the player: Equalizer sits beside Instant Mix and a Speed button beside Repeat shows the current speed, such as 1.25×. Each opens a compact panel with its title, summary and main action always in view, as a sheet on phones or a popover pointing at the button on desktop; press the button again to close it',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'The Speed & Pitch panel is quicker to use: one-tap speeds from 0.5× to 2×, a compact preset dropdown with a menu to save, update, rename or delete presets, hold-to-repeat − and + buttons, haptic ticks on every ruler line as you drag (stronger at each 0.10 and at 1.00×), supported ranges shown only at a limit, and pitch controls hidden where the audio backend cannot change pitch',
      ),
      ChangelogEntry(
        'On desktop, Ctrl+. and Ctrl+, (Cmd on macOS) change playback speed by 0.10× and Ctrl+0 resets it, with a brief confirmation; all three can be reassigned in Desktop Shortcuts',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'The compact desktop Mini Player menu now shows whether Shuffle and Repeat are on and adds Speed & Pitch and Equalizer',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'A mini Equalizer in the player lets you turn EQ on or off, see a larger response graph and pick any of your presets or imported headphone profiles from a dropdown (choosing one turns EQ on), with Open Equalizer for detailed editing',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'The Now Playing settings sheet is taller and draggable, with a Sound section holding Speed & Pitch and the mini Equalizer, and it closes before Speed & Pitch opens instead of stacking two sheets',
      ),
      ChangelogEntry(
        'Leaving the Equalizer page returns you to where you opened it, re-opening Now Playing or the Mini Player; on desktop its back arrow no longer always jumps to Settings',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'The full-screen player keeps Play centred with the Equalizer and Speed buttons, including on narrow phones, and the Speed & Pitch and Equalizer sheets now sit above Android navigation buttons and gesture bars',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Desktop albums open and close with a fast fade that respects reduced motion, and the Liked Albums Next arrow keeps its accessible label without hover text',
      ),
      ChangelogEntry(
        'Album and artist grids fit more columns on wide screens without oversized artwork; choose Auto, Small, Medium or Large artwork in Appearance, and album pages load enough items to fill the available view',
      ),
      ChangelogEntry(
        'Liked artists and albums now use compact horizontal previews with See all, bringing liked songs closer to the top; Home Recently Liked previews also adapt to the available width',
      ),
      ChangelogEntry(
        'Downloaded-only liked previews now filter the complete collection before choosing visible items, so eligible downloads beyond the old six-item preview are no longer missed',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Song rows show artist, album and duration columns when space permits, with aligned headings and a # track-number heading in full collections; repeated playlist tracks keep their individual actions',
      ),
      ChangelogEntry(
        'You Might Like stays compact on desktop; automatic recommendation cycling on touch devices is now optional, disabled by default, and pauses during interaction or when the page is inactive',
      ),
      ChangelogEntry(
        'The desktop player keeps elapsed and total playback times visible in small windows and with enlarged text, including a time preview while seeking',
      ),
      ChangelogEntry(
        'Radio stations now use compact cards that adapt to the available width instead of stretching across wide windows',
      ),
      ChangelogEntry(
        'Desktop player action tooltips no longer corrupt accessibility state or flood logs with repeated Flutter semantics assertions while browsing',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Check for updates on mobile data now reaches its bounded newest-album check even when an automatic index probe is pending',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Repair Library now finishes large confirmed changes when unavailable songs need review, while preserving earlier review decisions',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Repair Library and full syncs recover after repeated server rescans once a stable scan is observed, instead of remaining deferred indefinitely',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Automatic checks widen their discovery window when the library is far behind the server and schedule a full reconciliation when the backlog persists',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'The library screen shows a backlog notice while album details are still loading after a sync, and pending task counts now update live instead of only after a run finishes',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Most Played Tracks now orders plays with the same count deterministically by how recently a song was played, so the section stops shuffling between refreshes',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Liked content and playlists now share one freshness clock with the rest of sync, so a completed sync can no longer leave favorites stale behind a hidden timestamp',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Albums and artists whose server IDs change after a rescan now relink automatically from stable MusicBrainz identifiers or their songs, keeping favorites and ratings; unclear cases join the Unavailable Items review list',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Relinking an item manually now shows a preview of the old and new metadata plus everything that carries over, and re-checks the selection before applying it',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Unavailable Items entries show why they need review (missing, ambiguous, or conflicting evidence) and whether they are songs, albums, or artists',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'A single failed media fetch no longer hides a favorite from shuffle or Play All; only validated catalog evidence removes items from bulk selection, and offline copies always stay playable',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Corrupt cached artwork is evicted and refetched once; missing covers trigger a targeted metadata refresh, including HTTP 200 error pages, and error documents are never cached as artwork',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Navis now detects server library rescans and refreshes changed metadata automatically on the next check',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Upgrading schedules a one-time resumable library repair to apply the recovery changes to existing catalogs, while preserving downloads and respecting mobile-data consent',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Songs whose server IDs change after a rescan are relinked automatically when evidence is unambiguous; ambiguous cases stay in a new Unavailable Items review list instead of disappearing',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Recovered favorites keep their original like time and are restored to the server so other clients see them; missing-but-favorited items keep their likes and downloads',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Changed covers reload after library repairs without clearing unrelated artwork, and cached or downloaded images respect memory decode limits',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Rapid Next, Previous and queue selections track the latest requested position, and older playback work no longer overrides a later Pause command',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library sync preserves tracks and newer local edits when server responses are incomplete, and keeps external results out of the server catalog',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Remote favorites now appear in Liked with their metadata without adding external releases to your server library',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Likes and ratings sync through a durable retry queue, including album and artist favorites and offline rating changes',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Check for updates and Repair Library now refresh Likes and playlist headers even while music is playing, while scheduled sync remains conservative and unused genre metadata is no longer fetched or offered in Android Auto',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Check for updates now reports work completed within its safe sync limit and keeps the remaining library refresh queued',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Automatic checks discover new releases, refresh older track metadata in bounded batches, and resume interrupted sync work',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Full-screen setup and library repairs now open the safely rebuilt library when only incomplete server album details remain, then retry those albums during later syncs',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Playlist sync preserves repeated tracks and detects changed playlist contents even when the track count stays the same',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Android background sync correctly reads Wi-Fi metering when the app is closed',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Permanent downloads in Android custom folders now survive server removals and identity relinking instead of being mistaken for missing files',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Cancelling sync also cancels waiting repairs, while mixed local and remote album responses preserve their correct library membership',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Large library checks, repairs and album-detail loading now yield during metadata processing and avoid unnecessary database writes to keep browsing responsive',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Sync diagnostics retain bounded phase, retry and pending-work evidence across restarts to help explain incomplete checks and repairs',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'The full-screen player now shows a visible loading indicator while a remote song starts',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Instant Radio now blends your likes, recent listening, and server recommendations, with playable local music when offline',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Server mix uses standard Subsonic recommendations with compatibility fallbacks, while Last.fm Same Vibes keeps partial matches and fills gaps from your server',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Mixes and Instant Radio preserve the existing queue when preparation fails, report actual track additions, and cancel stale refills when stopped or replaced',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Instant Radio respects Home Liked only and Downloaded only filters, with visible loading, fallback and retry feedback',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Android Auto Instant Radio now uses the same personal radio as Home',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Navis now ships its own typeface, Inter, so text looks the same on Android, iOS, Linux, Windows and macOS, with a consistent type scale for headings and steady, evenly spaced numbers in durations and counts',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Buttons, chips, cards, menus and text fields share one visual language: secondary buttons and filter chips use softer rounded outlines, cards sit flat on tinted surfaces, and text fields and dropdowns use the same rounded outline everywhere, including first-run setup. The phone search field is now a filled search bar with a search icon',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Album, playlist, artist and Liked Songs actions follow one hierarchy on every screen: a filled Play, a tonal Shuffle and outlined secondary actions, with icon-sized versions on phones. Album headers now read like "2026 • 16 songs • 52 min", keep Like, Download, Rating and a single Filter button together, and show a badge when the track list is filtered. Section headings share one style across Home, Library, Search and artist pages',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'On desktop, album cards show a Play button on hover, song-row actions stay quiet until you point at or focus a row (liked and downloaded songs keep their icons), and album track lists no longer repeat the album name in every row. A failed library sync now shows a calm, dismissible notice instead of a bright red bar. Now Playing on phones shows dots under the details line so it is clear that tapping it reveals more, and the artist and album links are quieter',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Instant Mix now sits in the transport on phones as well as desktop, so Play stays centred between matching controls. Shuffle moved to the queue header because it reorders the queue, and the Queue button shows a small shuffle badge while shuffle is on',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Corner rounding, success colours and small text now come from shared design tokens, so panels, cards and confirmations look the same everywhere. Artist lists use flat, denser rows that match song lists',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Speed & Pitch rulers now glide to values picked with chips, presets, Reset or the − and + buttons, ticking as they pass each line like a swipe. The speed chips are 0.5× to 1.5× with 1× centred, the pitch toggle is now Pitch Lock ("Match pitch to speed."), and setting titles and buttons use consistent Title Case. Album headers show the artist on its own line with the year, song count and length beneath',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        "You Might Like on phones shows whole, uncropped square covers in a swipeable cover flow, with the title, artist, year, song count and why it was picked beneath, a Play button on the focused cover, and a soft wash of the cover's colours behind it. On desktop the track list gains the same reason line and Play and Shuffle buttons",
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Song tables on desktop now line up Artist, Album and Time exactly under their headings, and desktop pages use the full window width on wide displays',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'While Pitch Lock is on, the pitch control shows a link icon and keeps its values at full contrast instead of greying them out, without the inactive step buttons',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        "The You Might Like colour wash is now a smooth gradient drawn from each cover's colours, so it no longer looks pixelated on wide displays, and it blends between picks. In song lists, the Remote badge sits beside the title instead of on its own line, so remote songs line up with the rest",
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'The You Might Like track lists on desktop are more compact, and unmatched weekly-playlist tracks show a short "Not on server" or "Unclear match" label beside the title (with the full explanation on hover) instead of an extra line',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Missing album artwork now shows a softly shaded tile with an icon sized to the cover, so grids, headers and the Mini Player no longer look broken where art is absent',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        "On wide Home layouts the You Might Like arrows sit beside the cover strip instead of covering the track list's menus",
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Common playback speeds stay on one row in the Speed & Pitch popover and phone sheet',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Artist album counts read "1 album", the Liked Artists heading and album Rate label are fully localizable, the search clear button is labelled Clear search, and first-run setup text can now be translated',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.3.1',
    released: '2026-08-26',
    entries: [
      ChangelogEntry(
        "Recently Added now follows your server's complete newest-feed order through manual refreshes and library rebuilds, never the time Navis synced an album",
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Opening a remote release now preserves its remote status and artist relationship even when the detail response is incomplete or inconsistent, keeps its tracks visible, and keeps it out of Home and Albums until it is on your server',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'This update performs a one-time full library resync on your next unmetered connection, preserving downloads while applying the corrected order across your catalog',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.3.0',
    released: '2026-08-26',
    highlights: [
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.setup,
        title: 'First-run setup',
        body: 'Pick appearance, playback, downloads and scrobbling up front',
      ),
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.sync,
        title: 'Repair or rebuild',
        body: 'Fix the library without losing anything, or start fresh',
      ),
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.library,
        title: 'Remote releases',
        body: 'Artist pages show every release, clearly labelled',
      ),
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.audio,
        title: 'Vorbis streaming',
        body: 'Transcode to Vorbis alongside MP3, AAC and Opus',
      ),
    ],
    entries: [
      ChangelogEntry(
        'Now Playing shows a compact transcode indicator beside the active audio quality instead of a text prefix',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Streaming quality settings can now request Vorbis transcoding alongside MP3, AAC, and Opus',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'After a required library rebuild, first-time setup now prepares the first visible Home artwork so Home feels ready when you arrive',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Sync Settings now separates non-destructive Repair Library from Reset caches & rebuild library, clearly showing what each action keeps or removes',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library sync now keeps a redacted, restart-safe history of checks, repairs, and recovery outcomes',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Navis now offers a full-screen first-run customization flow for appearance, playback, downloads, queues, and optional ListenBrainz or Last.fm setup',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Album and liked-song queueing are now enabled by default',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Artist pages now load missing releases from your server and remote catalogues, while album tracks load when you open each release',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Remote releases are now clearly labelled, load their tracks with progress feedback, and stay out of your main Albums library',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Existing installations now automatically renew their library cache and rebuild before first-run setup, while keeping downloaded music',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Album titles remain readable on light artwork, and remote playback now shows its loading state consistently in the full-screen player',
        type: ChangelogEntryType.fix,
      ),
    ],
    specialThanks: ['To AJDxB for giving me the on-boarding page idea.'],
  ),
  ChangelogVersion(
    version: '1.2.10',
    released: '2026-08-25',
    entries: [
      ChangelogEntry(
        'Manual library refresh now always runs catalog discovery instead of being mistaken for a queued album-detail update',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Remote playback now retries safely at the current position before advancing, so failed seeks, interruptions, and queue loading do not restart songs unexpectedly',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry('AJ owes me livers in a cooler.'),
      ChangelogEntry(
        'Updated Navis to the current Flutter dependency release train across its supported platforms',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Linux desktop development builds now install a resolvable application launcher',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Updated the cross-platform development, diagnostics, and release workflow documentation',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.2.9',
    released: '2026-08-23',
    entries: [
      ChangelogEntry(
        'Existing downloads now reconcile faster, import clear matches automatically, and offer a cover-art review screen for files needing a manual match',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Titles, labels, menus, and empty states now use consistent title case throughout the app',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library and Settings now leave a little more breathing room at the top on portrait phones',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.2.8',
    released: '2026-08-21',
    entries: [
      ChangelogEntry(
        'Android custom download folders now work through the system folder picker, with safe import, offline playback, rescans, and preservation of unrelated files',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.2.7',
    released: '2026-08-21',
    entries: [
      ChangelogEntry(
        'Navis can now safely import existing permanent downloads from a custom folder, preserving files it cannot identify and remembering imported tracks for future installs',
        type: ChangelogEntryType.newFeature,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.2.6',
    released: '2026-08-21',
    entries: [
      ChangelogEntry(
        'First-time setup, Repair Library, and library cache rebuilds now use a dedicated full-screen progress experience and open Home only after the rebuilt catalog is ready',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Resetting or repairing the library keeps downloaded music and provides retry, mobile-data, and sign-out recovery options when rebuilding cannot finish',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Manual library refresh now reliably resumes its new-album discovery after reconnecting',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Tapping a liked track on Home now follows the same full liked-queue preference as the Library',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Desktop View now saves its size before the app closes',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Desktop Home song rows now offer direct actions instead of misleading navigation arrows',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop song lists now share responsive Like, Download, and More controls, while remote-only songs remain read-only',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Album, artist, and playlist playback now keeps matched remote songs in the requested queue',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library and Settings remove redundant page titles on portrait phones while keeping their context visible',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Sync Settings now clearly distinguishes foreground checks from Android background scheduling',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Older installations now refresh their library cache and rebuild the library once while keeping downloaded music',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.2.5',
    released: '2026-08-17',
    entries: [
      ChangelogEntry(
        'Playback startup now offers cache reset and sign-out recovery controls instead of trapping you on a loading screen',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Now Playing transport changes are smoother on mobile, with calmer automatic advances and clearer restart and queue-edge feedback',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Fixed Windows media controls so system playback, seeking, shuffle, and repeat reliably follow Navis playback',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed desktop More and right-click menus failing to open until after navigation',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed Android Auto opening from a cold phone start and made media browse refreshes reliable',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Desktop Lyrics now keeps the current track visible',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Artist Top Tracks now has an artwork-led playlist detail view',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Home playlist song controls now have a clearer More label',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Liked song controls now use clearer, correctly anchored More menus',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Match Flow song controls now clearly label the remove action',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Search now clearly labels its query-clear control',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Sync Settings now presents desktop status in a clearer, safer summary',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Home recommendation actions now have clearer labels',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Recovery screens now remain usable with large text on small displays',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Artist view controls now clearly describe grid and list changes',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Weekly playlist recovery states are now ready for translation',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library filtering and Playback headings are now ready for translation',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Artist Top Tracks controls now have a clearer More label',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Add to Playlist controls now have a clearer close label',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Sign-in password controls now have clearer Show and Hide labels',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Queue controls now have a clearer close label',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Fullscreen artwork controls now have clearer close labels',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Phone Play and Pause controls now have clearer long-press labels',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Download failure notifications no longer expose internal track IDs',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library Sync notifications now provide safe recovery guidance',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Album navigation and actions now have clearer long-press labels on phones',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Now Playing Like feedback now respects reduced-motion preferences',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Match Flow recovery notices are now ready for translation',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Update download failures now provide clear recovery without technical details',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Queue loading errors now explain how to recover without technical details',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library filters and sorting now remain readable with large system text',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Missing queue tracks now explain what happened without internal IDs',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Sync status messages now use clearer resume labels',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'The Android exit prompt is now ready for translation',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Battery and playback prompt labels are now ready for translation',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Compact desktop album pages now keep tracks visible alongside album actions',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Weekly playlist availability and playback actions are now ready for translation',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Artist Top Tracks now keeps the artist name visible when no tracks are available',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop quick-search and Home action labels are now ready for translation',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Playlist Detail now uses a full-width workspace header',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop About now uses a responsive overview for usage, links, and updates',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Privacy information now uses a clearer responsive desktop reading layout',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Match Flow now uses the full desktop workspace with New Flow in the header',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Appearance settings now use a focused workspace with a direct return to Settings',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Keyboard Shortcuts now uses a focused workspace with a direct return to Settings',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Window settings now use a focused workspace with a direct return to Settings',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Cache Settings now keeps storage controls focused with a direct return to Settings',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Configuration actions now stay reachable at larger system text sizes',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Configuration controls, validation feedback, and secret-field tooltips are now ready for translation',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Configuration now keeps independent external services side by side on wide windows',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Artist pages now keep their header, actions, and album layout visible while details first load',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Artist pages now keep their identity, album count, and More action stable while details refresh',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Older partial library migrations no longer prevent Android playback startup',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Error messages now stay visible until dismissed and keep their Dismiss action clear',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Radio filters now explain when no stations match and offer Show all stations',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Artist actions now offer Play, Shuffle, Add to Queue, and Like from More, long-press, or desktop right-click',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Artist Top Tracks More now uses the same focused desktop menu as right-click',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Album-track More and right-click actions now use one focused desktop menu',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Downloaded-track menus now separate the destructive Remove Download action',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Download Quality now uses a focused dialog on desktop while keeping the mobile sheet',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Add to playlist now uses a focused dialog on desktop while keeping the mobile sheet',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop playlist ownership actions now open a focused anchored menu from More or right-click',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Weekly playlist track actions now use the same anchored menu from the desktop More button and right-click',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Offline mode now uses a calmer status treatment while Navis retries in the background',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library now opens Appearance settings directly when all library pages are disabled',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Sync Settings now uses a continuous workspace with a clear return to Settings',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Configuration now keeps connection and external service settings in one clearer workspace',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Playback settings now has a clear return to Settings and a more focused reading width',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop About now has a direct return to Settings while keeping its app and data overview focused',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Downloads search now lets you restore the full Queue or Downloaded list directly from an empty result',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Weekly playlists now keep their track layout visible while loading and offer clearer recovery when unavailable',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop weekly playlists keep their Back button without repeating the page title',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Now Playing artwork tint now changes more quickly and respects reduced-motion preferences',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Search now clearly distinguishes no matches from a recoverable loading failure',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Fullscreen artwork now keeps its preview visible until the full-resolution, zoom-ready image is ready',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Album artwork no longer flashes when the opening or return animation settles',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'On phones, album details now fade in as a complete page without artwork motion',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Navigation and album artwork return transitions now respect your system reduced-motion preference',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Home carousels now stop auto-advancing and switch instantly when reduced motion is enabled',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'The selected mobile navigation destination now stays labeled for clearer orientation',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Compact landscape navigation now has accessible destination names and hover labels',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Status messages now announce themselves to assistive technology',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Search now uses an integrated command strip and continuous results workspace',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Library is now a continuous workspace, and collapsed navigation stays available as an icon rail',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Home now uses a calmer continuous desktop workspace while keeping album cards easy to scan',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Downloads now keeps its Back action, tabs, and search together in one compact workspace strip',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Settings now uses a focused preference list with clearer group hierarchy',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Settings labels are now ready for localization across desktop and mobile',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Status messages now respect your system reduced-motion preference',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'The expandable player now respects your system reduced-motion preference',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'The queue now respects your system reduced-motion preference',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Like feedback now respects your system reduced-motion preference',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Fullscreen artwork now respects your system reduced-motion preference',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Now Playing metadata changes now respect your system reduced-motion preference',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Wide Now Playing panels now respect your system reduced-motion preference',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Song action menus now group playback controls and clearly separate download removal',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Album refresh and radio loading errors now give clear recovery guidance',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Playback Settings and Match Flow errors now offer clear retry guidance',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Album action menus now clearly separate download removal',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Playlist track actions now use the same compact desktop menu for right-click and More, while phone keeps its touch sheet',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Long mobile album titles now size down when they can fit cleanly',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Album card titles and artists now fade in smoothly when returning from an album page',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Album artwork now opens with a steadier transition from Home, Library, Search, Artist, and Genre views',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Check for updates on mobile data now performs a bounded recent-album discovery, so new and changed albums can be found without downloading the full song index',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Recently Added now preserves known server album dates through full-library syncs, keeping its order stable without a cache reset',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library sync reliability has been improved.',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library sync now has stronger regression coverage for bounded mobile discovery and catalog-promotion date preservation',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Android background-sync reliability work now has a documented closure plan for truthful scheduling, worker failures, live network policy, and device certification',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.2.4',
    released: '2026-08-13',
    entries: [
      ChangelogEntry(
        'Check for updates on mobile data now safely finds recent changed albums instead of stopping at an unchanged server cursor',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library Recently Added order now stays stable after a full sync when a server omits an album creation date',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Android can now recover eligible automatic library checks through the system scheduler after the app process exits, with Sync Settings showing the requested cadence and safe outcome',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Check for updates now always looks for recent new albums, even when a server reports no artist-library change',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Check for updates now scans a wider recent-album window, so new albums beyond the first server page are discovered',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'A Check for updates started offline now resumes its full new-album discovery after reconnecting instead of stopping at an unchanged server cursor',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library sync now honors the configured automatic interval instead of repeatedly forcing pending verification work every two minutes',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Automatic library checks now keep their next scheduled time across app restarts, so reopening Navis does not restart the sync interval',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Opening Liked now stays offline-first and no longer starts a background library synchronization',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Repair Library now uses the standard full-library song index and safely falls back to album details instead of resuming a legacy wildcard search',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Repair Library now clearly shows when a large server-side deletion needs your confirmation before changing the local library',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'You can now discard a pending Repair Library candidate without changing your current offline library',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Repair Library now completes song collection before evaluating server-missing tracks, preventing a false large-deletion warning on an existing library',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Liked music now stays visible after one incomplete server response; Navis waits for a second confirmed absence before removing a like locally',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Opening Navis no longer restarts a paused Repair Library operation; repairs resume only when you request them',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry('Already missing 1.2.3'),
      ChangelogEntry(
        'Returning to Navis no longer submits duplicate automatic sync checks for the same lifecycle event',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Sync Settings now shows when automatic catalog work is waiting for a retry cooldown after a failed sync',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'A partial server artist response can no longer remove an existing offline album during an incremental sync',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Sync Settings now shows the latest safe library removal and its aggregate counts, even after later no-op checks',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.2.3',
    released: '2026-08-11',
    entries: [
      ChangelogEntry('Loving you is as easy as 123'),
      ChangelogEntry(
        'Repeat repairs of very large libraries now reuse verified unchanged album tracks when a server caps its bulk song index, avoiding a long late album-by-album wait',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library recovery controls now clearly distinguish safe metadata repair from a cache reset that keeps downloaded music',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Repair Library now shows progress immediately and keeps its final album fallback faster while music is playing',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Large-library scans now continue correctly when a compatible server returns shorter catalog pages than requested',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library repair now distinguishes song-index scanning from the remaining album-detail fallback and shows a live indexed-song count',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.2.2',
    entries: [
      ChangelogEntry(
        'Home now keeps library-sync status on the Navis logo, while Library provides the detailed progress and recovery controls',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Startup sync now waits for its signed-in server connection to become ready instead of briefly showing a false metadata-sync failure',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Refreshing a large library now brings in newly added albums immediately instead of waiting for a long artist verification cycle',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Subsonic connections now identify Navis to work reliably with strict reverse proxies',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.2.1',
    released: '2026-08-11',
    entries: [
      ChangelogEntry(
        'Library sync is now more reliable: background, manual, and repair requests share one coordinated operation so progress and failures stay accurate instead of briefly disappearing',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Missing rolling-cache files are now detected and removed immediately before playback safely falls back to streaming, without requiring a manual library repair',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'New connections stay on Home while the library is syncing, with persistent progress and retryable failure feedback',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Repair Library and full sync now coordinate safely with startup work for a more dependable recovery experience',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.2.0',
    released: '2026-08-10',
    highlights: [
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.desktop,
        title: 'Desktop View',
        body: 'A consistent workspace down to 800×600',
      ),
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.player,
        title: 'Mini Player',
        body: 'Playback and volume in a compact window',
      ),
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.sync,
        title: 'Guided first sync',
        body: 'Clear progress, offline retry and mobile-data consent',
      ),
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.queue,
        title: 'Now playing everywhere',
        body: 'The current song is highlighted in every list',
      ),
    ],
    entries: [
      ChangelogEntry(
        'New connections now open Home immediately while the initial library sync continues in the background with visible progress and retryable failures; failed automatic syncs remain visible until a meaningful retry result replaces them',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'First-time server connections now show a cancellable initial library setup with clear progress, offline retry, and mobile-data consent',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Signing back into the same server account now safely reuses its committed local library, while switching server or account requires confirmation before local data is replaced',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Signing out now reliably stops playback and radio, clears queues and pending server work, and waits for active syncs and downloads to stop',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Playback startup now keeps loading and automatically retries transient audio initialization failures',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Mini Player now opens at a balanced 720×405, returns to that size after mode prompts, keeps volume neatly beneath its controls, and shows both resize choices in short windows',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Mini Player controls are now compact transparent right-edge buttons with icon-only hover feedback and quick panel-aware fades; they stay clear of track details and hide for Queue, Lyrics, and other embedded panels. Queue now closes with a matching smooth reverse transition, and Linux Wayland clearly explains when its compositor cannot provide always-on-top',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Navis now always starts in Desktop View and restores your last Desktop window size, even if it was closed while Mini Player was active',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Favorite, Lyrics, Queue, Mini Player, and volume now stay directly visible across every supported Desktop View size',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Desktop and Mini Player layouts now stay balanced at unusual aspect ratios, with centered compact metadata and a firm 560×360 Mini Player minimum',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Desktop now stays in a consistent workspace down to 800×600, with its volume-ready bottom player always present and no phone-layout fallbacks',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'The new same-window Mini Player keeps playback, volume, pinning, and a quick return to Desktop View available in compact windows',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'The current or loading song is now highlighted consistently across library, Home, search, downloads, artist, playlist, and queue views without shifting queue track numbers',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop clients now reopen at your previous Navis volume, including mute, and Unmute restores the last audible level',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Search now keeps the best matches first while preferring music already on your server, and remote results use clearer context-aware Remote labels',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Remote labels now appear consistently in weekly recommendations, Home song lists, liked songs, artist top tracks, Match Flow, queues, and downloads without changing row alignment',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Remote label tooltips no longer flood desktop logs or destabilize accessibility when repeatedly shown and hidden',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'The update summary now keeps every change readable when it appears over an active player view',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library repairs now fall back to the server artist index when its separate artist-list endpoint is unavailable, so compatible servers can resume safely',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Large Library Repairs now keep a fast, bounded concurrent album fallback when a server search result window cannot return every song at once',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library Repairs now continue through server-capped song-search pages instead of needlessly falling back to slow album-by-album downloads',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Manual library refresh now includes liked music, playlist headers, and genres alongside catalog updates',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Manual library refresh now resumes queued catalog work while music is playing instead of deferring the refresh behind it',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library song hydration progress now advances only after song data is safely written, while catalog discovery uses an activity indicator instead of a misleading percentage',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library setup now waits for an already-running sync instead of briefly reporting a false failure, and completed syncs keep you on the page you are viewing',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'When a viewed album, artist, or playlist is confirmed removed, its page now stays open with a Back to Library action instead of navigating you away',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Release validation now exercises live app-owned screenshots, responsive desktop states, playback indicators, volume restoration, and authentication lifecycle in isolated profiles',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Navis now uses a refreshed, precisely centred logo and background-free circular platform icons',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.1.1',
    released: '2026-08-05',
    entries: [
      ChangelogEntry(
        'Seeking on desktop no longer hangs while a track is still caching; playback stays on a seekable stream while the rolling cache fills in the background',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Seeking back into already-heard audio on desktop is smoother and no longer forces a full stream rebuild',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.1.0',
    released: '2026-08-05',
    entries: [
      ChangelogEntry(
        'Background library sync stays on unmetered networks by default, with updates-available notices and one-time mobile-data sync when you need it',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library sync is adaptive and resumable: low-data checks, targeted updates, safer full repairs that apply only real changes, and better liked and playlist reconciliation',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop playback is more responsive; streamed tracks now fill the rolling cache on Linux, Windows, and macOS',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Fixed interrupted library repairs, playback startup glitches, Home refreshes during sync, and unstable seek or duration updates',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.15',
    released: '2026-07-30',
    entries: [
      ChangelogEntry(
        'Metadata sync now keeps individual artist and album failures pending, retries only unfinished items, and preserves the server cursor until verification completes',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Previous-track restarts and end-of-queue Next presses now use distinct replay and boundary feedback instead of looking like a track change',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Android Auto now opens with Liked, Recent, Playlists, and Library, with reliable search, queue order, resume, downloads, and genre browsing',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.14',
    released: '2026-07-26',
    entries: [
      ChangelogEntry(
        'Clearing the final queue item now closes the fullscreen player smoothly and leaves phone Back navigation responsive immediately',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Syncing while a cached remote song is playing now transfers its verified server identity without interrupting playback or invalidating the active cache file',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library update checks now verify 48 artists per pass and continue quietly, while preserving older unchecked artists when newer server changes arrive',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.13',
    released: '2026-07-26',
    entries: [
      ChangelogEntry(
        'Library refreshes now use the server sync cursor, verify newest albums, and continue large updates in bounded batches instead of requiring Force Full Sync',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Cached remote songs now move to their verified server identity when an exact match becomes available, preventing duplicate local entries without risky fuzzy matching',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Sync Settings now includes Check for updates and reports whether metadata is current, still being verified, or needs repair',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Previous track now reliably restarts the current song when there is no earlier queue item, including fullscreen artwork swipes and system media controls',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Instant Mix and Same Vibes now start from a fresh queue rooted at the current song, then keep recommendations appending at the bottom',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Adding songs near the end of playback no longer leaves the player paused or stuck at the seek position when advancing to the next track',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Opening the queue during active playback no longer triggers a provider rebuild error',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Queued remote tracks now recover from stream stalls by falling back to direct playback or skipping the failed track instead of staying stuck',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Downloaded songs now pre-cache standard-size cover art so offline album and track artwork is available more reliably',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'The offline server banner now switches to a quiet offline mode after repeated retry failures while continuing background checks',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'The update changelog dialog now labels bug-fix-only releases clearly and always links to the full changelog in About',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Refreshed core networking, connectivity, caching, and notification components and simplified Linux desktop media integration',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.10',
    released: '2026-07-12',
    entries: [
      ChangelogEntry(
        'Search category filters now show only matching results, so Songs no longer includes albums or artists when cached and server results are mixed',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'LRCLIB lyrics now prewarm first when songs play or enter the queue, with server lyrics used as fallback when LRCLIB has no match',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.9',
    released: '2026-07-07',
    entries: [
      ChangelogEntry(
        'Artist pages now include a virtual "This is" playlist powered by up to 50 Last.fm top tracks, with unmatched tracks kept visible for search',
        type: ChangelogEntryType.newFeature,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.8',
    released: '2026-06-30',
    entries: [
      ChangelogEntry(
        'Android stable releases now clean stale build outputs and verify APK contents before publishing so self-updates install the current app code',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Retired Listen Together and Voyage configuration strings are blocked from active Android release artifacts',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Artist Top Tracks with Album Queue keeps the ranked resolved queue and starts playback from the tapped track',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.7',
    released: '2026-06-30',
    entries: [
      ChangelogEntry(
        'Released a fresh stable version so older 1.0.6 installs detect the Listen Together retirement update correctly',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Artist Top Tracks with Album Queue now show the full ranked queue immediately on Android while playback finishes preparing in the background',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Retired Listen Together and Voyage settings are cleared during migration, including stored custom Voyage servers',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.6',
    released: '2026-06-30',
    entries: [
      ChangelogEntry(
        'Artist Top Tracks now honor Album Queue by queueing the resolved ranked top tracks and starting at the tapped song',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Now Playing and queue metadata stay on the tapped song while album-style queues finish filling in the background',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed album art loading stalling after a few covers when cached or missing artwork responses were not fully drained',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Listen Together is retired for now: Voyage backend sync has been removed and visible app entry points are hidden until the feature is redesigned',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.5',
    released: '2026-06-28',
    entries: [
      ChangelogEntry(
        'Re-introduced smart in-app updates: sideloaded Android builds can self-update, Google Play installs are redirected to the Play Store, and desktop keeps the existing updater',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Update checks now respect the auto-check setting, throttle background update checks to once every 24 hours, and record update download usage in data-usage stats',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library metadata sync tolerates missing albums and transient per-album failures instead of failing the entire scan, and automatically retries after a failed sync',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Automatic library sync now avoids daily full-library rescans, bounds noisy server index fanout, and refreshes starred/genre/playlist metadata less often to reduce background data usage',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Instant Mix now honors the legacy Subsonic instant-mix setting in Playback Settings instead of routing to Same Vibes, and active mix sessions reconcile when you switch between modes',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Listen Together now validates stored sessions on app launch — valid rooms auto-resume without a prompt, and expired or invalid sessions are cleared silently instead of showing a stale resume dialog',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Listen Together upgrades to Voyage voyage-sync.v4alpha1 for tighter multi-device sync — connection.ready handshake, explicit command frames, member status updates, and playback phase tracking',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Listen Together accepts Voyage voyage-sync.v4alpha1 and the legacy sync.v4alpha1 protocol alias during server rollout',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Voyage connection errors in Configuration now show the expected and supported protocol versions when Listen Together cannot negotiate a compatible server',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Instant Mix uses the server instant-mix endpoint for 50-track batches again, Same Vibes keeps its 5-track Last.fm fills, and both modes recover instead of staying stuck loading',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library resync and playlist refresh now trigger ListenBrainz weekly playlist discovery and rematching, including on fresh installs after token validation',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'ListenBrainz weekly playlists stay visible after matching completes, even when none of the recommendations match your server yet',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'ListenBrainz weekly playlist details now keep unavailable recommendations aligned with playable tracks and include a Match action to retry matching for one weekly playlist',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Same Vibes and Instant Mix no longer loop through repeated startup errors when only part of a recommendation batch can be queued',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Remote search3 tracks start playing more reliably after tap, including when re-selected from the library or during Listen Together queue changes',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.4',
    released: '2026-06-22',
    entries: [
      ChangelogEntry(
        'You Might Like can now include your ListenBrainz weekly recommendations, and song likes sync to ListenBrainz recording feedback when connected',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Weekly Exploration and Weekly Jams now appear as read-only virtual playlists in the playlist library, with normal play, shuffle, queue, download, and song actions for matched server tracks',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'ListenBrainz weekly matching now checks cached local songs first, limits remote search concurrency, handles duplicate exact matches more accurately, and avoids unnecessary ambiguous results',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop You Might Like panels now show complete scrollable song lists for albums and weekly recommendations instead of short previews',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library pages can now be reordered from Appearance settings, with per-page visibility controls including Albums across mobile tabs and desktop library navigation',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Weekly recommendation loading is smoother, with batched matching, database writes, and UI updates to reduce stalls while recommendations resolve',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Queued downloads now react when Wi-Fi-only settings or network type change, and compatible cached files are reused instead of downloaded again',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Rolling cache files can now be promoted to permanent downloads from the queue, stale missing-file cache records are cleaned up, and lower-quality cached files no longer block higher-quality download requests',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'The Previous control now restarts the current track when appropriate and only skips to the prior track near the start of playback',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Updated package dependencies including file picker, local notifications, and JSON annotations',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.3',
    released: '2026-06-15',
    entries: [
      ChangelogEntry(
        'Android releases are now prepared for Google Play, with Android self-updates removed, Play release tooling added, privacy information added, and release safety checks documented',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'External scrobbling now supports Last.fm and ListenBrainz alongside Subsonic/OpenSubsonic, with secure credential storage, validation, reconnect handling, and provider-aware offline retries (Last.fm scrobbling was later removed.)',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Listen Together now supports custom Voyage servers that can be added, edited, selected, and managed alongside bundled server defaults',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Voyage sync recovery is more robust, with protocol v2 support, clock-sync hardening, fewer duplicate queue seeks, and safer version negotiation',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Last.fm API key configuration has been restored in Server settings so builds can include a key while still allowing user-provided keys when needed',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Instant Mix and Same Vibes recommendations now insert after the current track so they keep your queue context instead of replacing what comes next',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Search can now prefer cached local results first, reducing network use and making repeat searches feel faster',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Mobile data usage is now tracked and reduced across artwork, sync, downloads, and playback flows, with clearer usage reporting in About',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Cached-first playback can now prefer downloaded or cached audio before remote streams when a local copy is available',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Navigation intents from album, artist, playlist, search, queue, and Now Playing actions are more stable across shell layouts and back-stack transitions',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Appearance settings, exact brand accent colors, icon rendering, and color picker behavior are more consistent across light and dark themes',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Android Auto browsing and real-car validation are more robust, with clearer media IDs, safer playback rules, diagnostic tooling, and dedicated test coverage',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Permanent downloads gained custom folders, readable artist/song paths, desktop folder actions, and safer cleanup of empty download directories',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Liked-tab play, shuffle, and queue-all actions include tracks from liked albums while deduplicating overlaps and respecting filters',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Listen Together rooms, Match Flow song chains, split artist releases, player polish, faster sync, and Android Auto reliability improvements from the 1.0 release are included',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Queue appends, cached-source seek recovery, Listen Together reconnects, room exits, and compact mini-player layout edge cases are more reliable',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.2',
    released: '2026-05-19',
    entries: [
      ChangelogEntry(
        'Custom download folders for permanent downloads — pick your own destination and Navis will move existing downloads there automatically',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Permanent downloads now use readable artist folders and song filenames instead of cache-style names, and existing downloads are migrated to match',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Downloaded-song actions now support desktop right-click and include a direct shortcut to open the containing download folder',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Removing downloads now cleans up empty artist folders without deleting your configured top-level download folder',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.1',
    released: '2026-05-19',
    entries: [
      ChangelogEntry(
        'Liked-tab play, shuffle, and queue-all actions now include tracks from liked albums, while deduplicating overlaps with individually liked songs and respecting current filters',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.0',
    released: '2026-05-19',
    entries: [
      // New
      ChangelogEntry(
        'Listen Together — host or join Voyage-backed synced rooms with shared queue control, live room status in the player bar, and collaborative or host-only room setups',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Experimental Match Flow — create song chains in Playback Settings so starting one track can automatically expand into follow-up songs',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Artist pages now split main releases from featured appearances for easier browsing',
        type: ChangelogEntryType.newFeature,
      ),
      // Improvements
      ChangelogEntry(
        'Now Playing, the mini player, and compact layouts are more polished, with richer metadata navigation and better desktop media integration',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library sync is faster and smarter — song pages load in parallel and tracks deleted from the server are reconciled locally',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Android Auto media browsing and projection support are more reliable, and cover art loading now prioritizes visible items for smoother scrolling',
        type: ChangelogEntryType.improvement,
      ),
      // Fixes
      ChangelogEntry(
        'Listen Together recovery is much more resilient — rejoin/resume, room exits, sync recovery, and listener seeking behave more reliably during disconnects',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Queue appends stay in order, cached-source seek recovery is more reliable, and compact wide mini-player layout glitches are fixed',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.9.9',
    released: '2026-04-18',
    entries: [
      ChangelogEntry(
        'Playback stays responsive while songs, radio streams, and queue changes are loading — stuck remote sources no longer trap the app until restart',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Player recovery is more resilient on Android — timed-out cached stream loads now fall back cleanly and background artwork/network tasks are isolated from playback control',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Lyrics lookup is now more consistent across remote and local playback — LRCLIB fallback can reuse the active track metadata even when the local source metadata path differs',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Recently played logging no longer crashes on duplicate history writes while tracks are switching quickly',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.9.8',
    released: '2026-04-12',
    entries: [
      // New
      ChangelogEntry(
        'User-configurable Last.fm API key — enter your own key in Settings > Configuration; no build flags required',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        "Android Auto: Search tab for finding music directly from your car's head unit",
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Android Auto: Instant Mix and Instant Radio controls added to the More tab, with an Instant Mix button in the player controls',
        type: ChangelogEntryType.newFeature,
      ),
      // Changes / improvements
      ChangelogEntry(
        'Settings page renamed from "Server" to "Configuration"',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Android Auto browse tree redesigned — Home, Recent, Playlists, and More tabs replace the previous flat layout; albums are shown at the root level',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Artist top tracks section is now hidden when none of the tracks are found in your library, rather than showing entries that cannot be played',
        type: ChangelogEntryType.improvement,
      ),
      // Fixes
      ChangelogEntry(
        'Scrobbling now records the correct listen time instead of the time the scrobble was submitted',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Artist top tracks no longer show or play songs from the wrong artists — improved matching prevents title collisions between tracks from different artists',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Android Auto album art now loads reliably — fixed a race condition that caused cover art to fail downloading',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Android Auto Instant Mix now correctly applies your album queue preference and shows accurate on/off state',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.9.7',
    released: '2026-04-10',
    entries: [
      // New
      ChangelogEntry(
        'New startup screen — the Navis logo appears centred with an animated ring that fills as the playback engine loads, then the logo flies up to its place on the home screen in a seamless transition',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Home screen quick controls redesigned — filter toggles (shuffle, favourites) sit on the left and action buttons (Instant Mix, Radio) sit on the right in a compact chip row below the Navis logo',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Album detail screen now lists all artists individually — each name is a tappable link that opens the corresponding artist page',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Full OpenSubsonic multi-artist support — albums tagged with multiple separate artists each get their own clickable chip; compound names like "Artist A & Artist B" are split into individual links even on standard Subsonic servers',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Library automatically performs a full resync on first launch after an app update so your library stays consistent with any data changes introduced by the new version',
        type: ChangelogEntryType.newFeature,
      ),
      // Fixed
      ChangelogEntry(
        "Album art on the home page's Recently Liked and Liked Tracks sections, and on the Liked page, now loads correctly — fixed a startup race condition that caused the cover art cache to crash before its database had finished opening",
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Cover art images no longer stop loading after a large amount of music is cached — fixed a background conflict that caused images to get permanently stuck until the app was restarted',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Android Auto home screen now shows album art behind the media controls',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed Android Auto home widget showing no controls or track info after playback started',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed audio downloads occasionally failing with a file-not-found error when the rolling cache was evicting files at the same time',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Artist names on the album detail screen no longer overflow — long or compound names wrap naturally across multiple lines',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Pressing play after the queue finishes now restarts playback from the beginning of the queue',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.9.6',
    released: '2026-04-08',
    entries: [
      // New
      ChangelogEntry(
        "Android Auto support — browse artists, albums, playlists, favourites, and podcasts directly from your car's head unit",
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Android Auto now playing screen adapts to car displays — large album art, oversized transport controls, and a seek bar sized for in-car interaction',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Added Album Queue setting in Playback Settings — when enabled, tapping a track in an album queues the full album and starts at that track',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Added Liked Queue sub-setting — when enabled alongside Album Queue, tapping a track on the Liked page queues all liked songs and starts at that track',
        type: ChangelogEntryType.newFeature,
      ),
      // Improved
      ChangelogEntry(
        'Redesigned login screen — new Material 3 card layout with app icon, password visibility toggle, and an insecure HTTP warning',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Login screen adapts to any screen size — portrait, landscape phone, wide tablet, and desktop each get a purpose-built layout',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Tapping a song now starts playback almost instantly — the app no longer waits for the full queue to load before you hear audio',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Tapping a different song while one is still loading now cancels the previous load and plays the new song immediately',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library sync no longer blocks playback — large song batches are broken into smaller database writes so reads can interleave',
        type: ChangelogEntryType.improvement,
      ),
      // Fixed
      ChangelogEntry(
        'Login fields scroll up above the keyboard when tapped so the text you are typing is always visible',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Album, artist, and playlist screens stay fully interactive while a queue action is in progress',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Cached and offline songs now play immediately even while a library sync is running in the background',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.9.5',
    released: '2026-04-03',
    entries: [
      // New
      ChangelogEntry(
        'Added "Add to Queue" option in the downloaded track menu',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Artist detail screen now has Play and Shuffle buttons',
        type: ChangelogEntryType.newFeature,
      ),
      // Improved
      ChangelogEntry(
        'Download search is now shared — one search bar filters both Queue and Downloaded tabs',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        '"Re-Download" replaced with "Change Download Quality" — pick Original, 320, 192 or 128 kbps and see your current quality highlighted',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Album detail screen has a new scroll-driven header — cover art shrinks into the toolbar as you scroll, with a gradient overlay and album name animation',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Rating button now smoothly expands into a star-picker pill and collapses back with an animation',
        type: ChangelogEntryType.improvement,
      ),
      // Fixed
      ChangelogEntry(
        'Fixed search bar keeping keyboard active after pressing back',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Removed emojis from release notes for better cross-platform compatibility',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed cover art flash and hero animation glitches on album detail screen',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed back button closing the app when at the root of a navigation branch',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.9.4',
    released: '2026-04-02',
    entries: [
      // New
      ChangelogEntry(
        'Tapping a downloaded track in the Downloads page now plays it directly',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Download buttons now show "Remove Download" when a song is already saved offline',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Added search to the Downloads page — filter your queue and downloaded songs by title or artist',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        "Added What's New page in About settings showing what changed in the current version",
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        "App now shows a What's New summary on first launch after an update",
        type: ChangelogEntryType.newFeature,
      ),
      // Improved
      ChangelogEntry(
        'Improved radio station switching reliability and reduced lag when stopping radio',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Swiping to remove a queue item no longer accidentally dismisses the queue, and dismissing no longer triggers item removal',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Update notifications now display actual release notes instead of a generic link',
        type: ChangelogEntryType.improvement,
      ),
      // Fixed
      ChangelogEntry(
        'Fixed download button in the Now Playing settings panel not working',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed download action remaining visible while a song is already queued or downloading',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed songs being re-downloaded automatically after library sync without user request',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed album art flickering during navigation transitions',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed playback controls freezing when Instant Mix is active',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed tooltip labels appearing on mobile after tapping icons',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.3.0',
    released: '2026-03-01',
    entries: [
      // New
      ChangelogEntry(
        'Added playback speed control in Now Playing and Playback Settings, with saved speed restored across sessions',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Added ReplayGain playback settings with track/album modes and pre-amp control for supported libraries',
        type: ChangelogEntryType.newFeature,
      ),
      // Improved
      ChangelogEntry(
        'Improved synced lyrics with full-screen live tracking, faster auto-scroll recovery, and tap-to-seek',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Added a playback warning when crossfade and gapless settings conflict',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.2.12',
    released: '2026-02-28',
    entries: [
      // Improved
      ChangelogEntry(
        'Hardened release pipeline with APK package/version/signature checks '
        'before publishing new assets',
        type: ChangelogEntryType.improvement,
      ),
      // Fixed
      ChangelogEntry(
        'Improved in-app update reliability by selecting only strictly newer '
        'release versions and deterministically preferring the matching APK '
        'asset for each tag',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Added APK pre-install validation for package/signature compatibility '
        'to prevent conflicting-package install attempts',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.2.11',
    released: '2026-02-28',
    entries: [
      // New
      ChangelogEntry(
        'Added full-screen album art viewer from album detail with smoother '
        'open/close transitions and pinch-to-zoom',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Added Appearance toggle for Dynamic Album Color to theme app accent '
        'colors from currently playing album art (off by default)',
        type: ChangelogEntryType.newFeature,
      ),
      // Fixed
      ChangelogEntry(
        'Fixed search/Now Playing navigation edge cases: closing queue no '
        'longer retriggers search, and expanding Now Playing no longer '
        'keeps the search keyboard active',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.2.10',
    released: '2026-02-27',
    entries: [
      // New
      ChangelogEntry(
        'Added configurable auto-sync interval (15m, 30m, 1h, 2h, 6h, 12h, '
        'or manual only) in Sync Settings',
        type: ChangelogEntryType.newFeature,
      ),
      // Improved
      ChangelogEntry(
        'Library now syncs automatically in the background on a periodic timer '
        'based on the chosen interval',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Sync staleness window is now driven by user settings instead of a '
        'hard-coded 1-hour window',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.2.9',
    released: '2026-02-27',
    entries: [
      // Improved
      ChangelogEntry(
        'Refreshing the home screen now rescans for app updates and APK '
        'availability',
        type: ChangelogEntryType.improvement,
      ),
      // Fixed
      ChangelogEntry(
        'Fixed version not being upgraded, causing an infinite update loop',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Release notes in the update dialog now render markdown formatting '
        'correctly (bold, headings, lists, etc.)',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.2.8',
    released: '2026-02-27',
    entries: [
      // New
      ChangelogEntry(
        'Added version changelog dialog on first launch after update',
        type: ChangelogEntryType.newFeature,
      ),
      // Improved
      ChangelogEntry(
        'Added double-press-to-exit confirmation when on the Home screen',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Tapping the Home icon while already on Home now scrolls to the top',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Smoother Now Playing drag-to-dismiss gesture with better '
        'velocity and snap thresholds',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Refined player expand/collapse animations for a more natural feel',
        type: ChangelogEntryType.improvement,
      ),
      // Fixed
      ChangelogEntry(
        'Fixed back button sometimes exiting the app instead of '
        'minimizing the Now Playing overlay',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Back button now consistently closes overlays before navigating',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
];
