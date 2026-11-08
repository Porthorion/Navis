#!/usr/bin/env python3
"""Small deterministic Subsonic fixture for auth lifecycle diagnostics."""

import argparse
import io
import json
import math
import os
import struct
import time
import wave
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


def _wav_bytes(seconds=4, rate=22050, hz=440, channels=1, bits=16) -> bytes:
    """Four seconds of 440 Hz (1760 whole cycles, so consecutive songs join
    phase-continuously) at the given sample rate. A song that lasts a whole
    number of seconds at a whole number of hertz ends on a zero crossing, so a
    tone of another frequency can follow it without a step. `bits` 32 makes a
    float WAV (format tag 3, which the wave module cannot write); every channel
    carries the same tone."""
    amplitude = 5000 / 32768
    samples = [amplitude * math.sin(2 * math.pi * hz * index / rate) for index in range(rate * seconds)]
    if bits == 32:
        data = b"".join(struct.pack("<f", value) * channels for value in samples)
        header = (
            b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt "
            + struct.pack("<IHHIIHH", 16, 3, channels, rate, rate * channels * 4, channels * 4, 32)
            + b"data" + struct.pack("<I", len(data))
        )
        return header + data
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(b"".join(struct.pack("<h", int(value * 32768)) * channels for value in samples))
    return output.getvalue()


AUDIO = _wav_bytes()
# Songs with their own sample rate (--song-rate), by song id.
SONG_AUDIO = {}
# Length in seconds of the songs --song-tone made longer (or shorter) than 4 s.
SONG_SECONDS = {}
def _cover_png(size=48) -> bytes:
    """A visible cover: orange and teal quarters, so screenshots can tell a
    rendered cover from the placeholder."""
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            orange = (x < size // 2) == (y < size // 2)
            rows.extend((240, 120, 30) if orange else (20, 150, 150))

    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(rows)))
        + chunk(b"IEND", b"")
    )


PNG = _cover_png()
ARTIST = {
    "id": "fixture-artist",
    "name": "Fixture Artist",
    "albumCount": 1,
    "coverArt": "fixture-cover",
}
ALBUM = {
    "id": "fixture-album",
    "name": "Lifecycle Album",
    "artist": "Fixture Artist",
    "artistId": "fixture-artist",
    "songCount": 1,
    "duration": 4,
    "year": 2026,
    "coverArt": "fixture-cover",
    "created": "2026-01-01T00:00:00Z",
}
SONG = {
    "id": "fixture-song",
    "title": "Lifecycle Tone",
    "album": "Lifecycle Album",
    "albumId": "fixture-album",
    "artist": "Fixture Artist",
    "artistId": "fixture-artist",
    "track": 1,
    "duration": 4,
    "bitRate": 352,
    "contentType": "audio/wav",
    "suffix": "wav",
    "size": len(AUDIO),
    "coverArt": "fixture-cover",
    "created": "2026-01-01T00:00:00Z",
}
ARTIST_ALBUMS = [ALBUM]
# Every album getAlbum can return. getArtist may list fewer (the manual
# discovery fixture's partial artist response), but the server still has them.
ALL_ALBUMS = [ALBUM]
# Song ids of albums whose single song is not "<album id>-song".
ALBUM_SONG_IDS = {}
INDEX_LAST_MODIFIED = 1780000000000
FAILURE_FLAG = ""
PARTIAL_ALBUM_FLAG = ""
ALBUM_ERROR_FLAG = ""
PARTIAL_ALBUM_ID = "fixture-incomplete-album"
# Seconds each stream or download takes, so concurrent transfers overlap.
MEDIA_SECONDS = 0.0
# Extra songs of the fixture album (downloads scenario), by id.
EXTRA_SONGS = {}
# Songs of albums whose song list is fixed (genres scenario), by album id.
ALBUM_SONGS = {}


def _configure_manual_discovery_fixture(omit_existing_artist_album=False):
    """Expose a new album without changing the artist-index cursor.

    This intentionally models the Navidrome/Subsonic gap that Navis must
    cover with its bounded newest-album discovery: the artist collection is
    unchanged, but an already-known artist has received a new album.
    """
    global ALBUM, ALL_ALBUMS, ALBUM_SONG_IDS, ARTIST, ARTIST_ALBUMS
    global INDEX_LAST_MODIFIED, SONG
    ARTIST = {
        "id": "fixture-existing-artist",
        "name": "Fixture Existing Artist",
        "albumCount": 2,
        "coverArt": "fixture-cover",
    }
    existing_album = {
        "id": "fixture-existing-album",
        "name": "Fixture Existing Album",
        "artist": ARTIST["name"],
        "artistId": ARTIST["id"],
        "songCount": 1,
        "duration": 4,
        "year": 2025,
        "coverArt": "fixture-cover",
        "created": "2025-01-01T00:00:00Z",
    }
    ALBUM = {
        "id": "fixture-new-album",
        "name": "Fixture Newly Added Album",
        "artist": ARTIST["name"],
        "artistId": ARTIST["id"],
        "songCount": 1,
        "duration": 4,
        "year": 2026,
        "coverArt": "fixture-cover",
        "created": "2026-08-01T00:00:00Z",
    }
    SONG = {
        "id": "fixture-new-song",
        "title": "Fixture Newly Added Tone",
        "album": ALBUM["name"],
        "albumId": ALBUM["id"],
        "artist": ARTIST["name"],
        "artistId": ARTIST["id"],
        "track": 1,
        "duration": 4,
        "bitRate": 352,
        "contentType": "audio/wav",
        "suffix": "wav",
        "size": len(AUDIO),
        "coverArt": "fixture-cover",
        "created": "2026-08-01T00:00:00Z",
    }
    ARTIST_ALBUMS = [ALBUM] if omit_existing_artist_album else [existing_album, ALBUM]
    ALL_ALBUMS = [existing_album, ALBUM]
    # The diagnostics clone seeds the existing album with this song.
    ALBUM_SONG_IDS = {existing_album["id"]: "fixture-existing-song"}


def _configure_downloads_fixture(song_count, distinct_covers=False):
    """One album of several songs, for concurrent download diagnostics.

    With distinct_covers every extra song names its own cover id (the image is
    the same), so changing track reaches a cover that is not cached yet.
    """
    global ALBUM, ALL_ALBUMS, ARTIST_ALBUMS, EXTRA_SONGS
    ALBUM = {**ALBUM, "songCount": song_count, "duration": 4 * song_count}
    ARTIST_ALBUMS = [ALBUM]
    ALL_ALBUMS = [ALBUM]
    EXTRA_SONGS = {
        f"fixture-song-{index}": {
            **SONG,
            "id": f"fixture-song-{index}",
            "title": f"Lifecycle Tone {index}",
            "track": index,
            **({"coverArt": f"fixture-cover-{index}"} if distinct_covers else {}),
            **({"size": len(SONG_AUDIO[f"fixture-song-{index}"])}
               if f"fixture-song-{index}" in SONG_AUDIO else {}),
            **({"duration": SONG_SECONDS[f"fixture-song-{index}"]}
               if f"fixture-song-{index}" in SONG_SECONDS else {}),
        }
        for index in range(2, song_count + 1)
    }


# (album, year, songs); a song is (title, genre names, send the legacy
# "genre" string only, like a plain Subsonic server).
GENRE_FIXTURE = [
    ("Night Drive", 2024, [
        ("Neon Lights", ["Hip Hop"], False),
        ("Back Alley", ["Hip-Hop", "Electronic"], False),
        ("Tail Lights", ["hip_hop"], False),
    ]),
    ("Slow Burn", 2022, [
        ("Ember", ["Rock", "Blues"], False),
        ("Ash", ["Rock"], False),
        ("Smoke Signal", ["Rock", "Hip Hop", "Jazz", "Soul"], False),
    ]),
    ("Blue Hour", 2019, [
        ("Midnight Set", ["Jazz"], True),
        ("Brushes", ["Jazz"], True),
    ]),
    ("Tokyo Pop", 2025, [
        ("Sakura", ["ジェイポップ"], False),
        ("Shibuya", ["ジェイポップ", "Electronic"], False),
    ]),
    ("Wide Open", 2021, [
        ("Prairie", ["Folk", "Country"], False),
        ("Dust", ["Folk"], False),
        ("Untagged Song", [], False),
    ]),
]


def _configure_genres_fixture():
    """Albums whose songs carry genre tags, for the Genres pages.

    Navidrome sends both the OpenSubsonic genres list and the legacy genre
    string; the Jazz album sends only the string, like a plain Subsonic server.
    """
    global ALL_ALBUMS, ARTIST, ARTIST_ALBUMS, ALBUM_SONGS, ALBUM
    albums = []
    for index, (name, year, songs) in enumerate(GENRE_FIXTURE, start=1):
        album_id = f"fixture-genre-album-{index}"
        rows = []
        for track, (title, genres, legacy_only) in enumerate(songs, start=1):
            row = {
                **SONG,
                "id": f"{album_id}-song-{track}",
                "title": title,
                "album": name,
                "albumId": album_id,
                "track": track,
            }
            if genres:
                row["genre"] = genres[0]
                if not legacy_only:
                    row["genres"] = [{"name": genre} for genre in genres]
            rows.append(row)
        album = {
            **ALBUM,
            "id": album_id,
            "name": name,
            "year": year,
            "songCount": len(rows),
            "duration": 4 * len(rows),
        }
        ALBUM_SONGS[album_id] = rows
        albums.append(album)
    ARTIST = {**ARTIST, "albumCount": len(albums)}
    ALBUM = albums[0]
    ARTIST_ALBUMS = albums
    ALL_ALBUMS = albums


def _configure_partial_album_fixture():
    global ALL_ALBUMS, ARTIST, ARTIST_ALBUMS
    ARTIST = {**ARTIST, "albumCount": 2}
    ARTIST_ALBUMS = [
        ALBUM,
        {
            **ALBUM,
            "id": PARTIAL_ALBUM_ID,
            "name": "Incomplete Fixture Album",
            "songCount": 2,
        },
    ]
    ALL_ALBUMS = ARTIST_ALBUMS


# Rescan scenario: a small library whose server side changes between two
# phases (the phase file holds "A" or "B"), as after a retag plus a rescan.
RESCAN_ENABLED = False
PHASE_FILE = ""
REQUEST_LOG = ""
RESCAN_SCANS = {
    "A": "2026-11-07T04:00:00Z",
    "B": "2026-11-07T12:00:00Z",
    "C": "2026-11-07T18:00:00Z",
    "D": "2026-11-08T02:00:00Z",
    "E": "2026-11-08T03:00:00Z",
    "F": "2026-11-08T04:00:00Z",
    "G": "2026-11-08T05:00:00Z",
    "H": "2026-11-08T06:00:00Z",
}
RESCAN_INDEXES = {
    phase: 1780000000000 + 600000 * index
    for index, phase in enumerate(sorted(RESCAN_SCANS))
}
RESCAN_ALBUM_COUNT = 100  # the bulk song path needs at least 96 pending albums
# Long enough that a queued song keeps playing through a sync (phase B of
# the playback check in rescan_snapshot_diagnostics.py).
RESCAN_SONG_SECONDS = 90


def _rescan_phase():
    try:
        with open(PHASE_FILE, encoding="utf-8") as handle:
            value = handle.read().strip()
            return value if value in RESCAN_SCANS else "A"
    except OSError:
        return "A"


def _rescan_library(phase):
    """Return (artists, albums, songs) for a phase. C is B after another scan,
    D and E move the retag on, F and G also remove sixteen albums.
    Phase B holds a ReplayGain
    retag (s1 changed, s4 cleared), s5 removed from a two-song album, a whole
    album (a7) removed, s2 moved a2 to a3, s8 renamed and re-artisted, and a
    genre on s9. One album of a hundred disappears, under the deletion guard."""
    b = phase != "A"
    # D, E: the retag moves on with each scan. F, G, H: sixteen albums vanish,
    # a large removal that waits for confirmation.
    track_gain = {"B": -3.5, "C": -3.5, "D": -2.0, "E": -1.0, "F": -1.0, "G": -1.0, "H": -1.0}
    removed = set(range(20, 36)) if phase in ("F", "G", "H") else set()
    artists = {
        "rs-artist-1": {"id": "rs-artist-1", "name": "Rescan Artist 1", "coverArt": "fixture-cover"},
        "rs-artist-2": {"id": "rs-artist-2", "name": "Rescan Artist 2", "coverArt": "fixture-cover"},
    }
    songs = {}

    def add(song_id, album_id, track, title=None, artist="rs-artist-1", gain=None, genres=()):
        row = {
            **SONG,
            "id": song_id,
            "title": title or f"Rescan {song_id}",
            "albumId": album_id,
            "album": f"Rescan {album_id}",
            "artistId": artist,
            "artist": artists[artist]["name"],
            "track": track,
            "duration": RESCAN_SONG_SECONDS,
            "size": len(AUDIO),
        }
        if gain is not None:
            row["replayGain"] = {"trackGain": gain, "albumGain": gain, "trackPeak": 1.0, "albumPeak": 1.0}
        if genres:
            row["genre"] = genres[0]
            row["genres"] = [{"name": name} for name in genres]
        songs[song_id] = row

    for n in range(1, RESCAN_ALBUM_COUNT + 1):
        if b and (n == 7 or n in removed):
            continue
        gain = -6.0 - n
        if b and n == 1:
            gain = track_gain[phase]
        if b and n == 4:
            gain = None
        title = "Renamed" if b and n == 8 else None
        artist = "rs-artist-2" if b and n == 8 else "rs-artist-1"
        genres = ("Jazz",) if b and n == 9 else ()
        add(f"rs-s{n}", f"rs-a{n}", 1, title, artist, gain, genres)
    add("rs-s2b", "rs-a2", 2)
    add("rs-s5b", "rs-a5", 2)
    if b:
        del songs["rs-s5"]
        songs["rs-s2"] = {**songs["rs-s2"], "albumId": "rs-a3", "album": "Rescan rs-a3", "track": 2}
    albums = {}
    for song in songs.values():
        album_id = song["albumId"]
        album = albums.setdefault(album_id, {
            "id": album_id,
            "name": song["album"],
            "artist": song["artist"],
            "artistId": song["artistId"],
            "songCount": 0,
            "duration": 0,
            "year": 2026,
            "coverArt": "fixture-cover",
            "created": "2026-01-01T00:00:00Z",
        })
        album["songCount"] += 1
        album["duration"] += song["duration"]
    for artist in artists.values():
        artist["albumCount"] = sum(1 for a in albums.values() if a["artistId"] == artist["id"])
    return artists, albums, songs


def _log_request(endpoint, query):
    if not REQUEST_LOG or endpoint in {"stream", "download", "getCoverArt"}:
        return
    keep = {key: query[key] for key in ("type", "size", "offset", "songCount", "songOffset", "query") if key in query}
    with open(REQUEST_LOG, "a", encoding="utf-8") as output:
        output.write(json.dumps({"endpoint": endpoint, "query": keep}) + "\n")


def _root(**content):
    return {
        "subsonic-response": {
            "status": "ok",
            "version": "1.16.1",
            "type": "navis-fixture",
            "serverVersion": "1.0.0",
            **content,
        }
    }


ANNOTATION_LOG = None


class Handler(BaseHTTPRequestHandler):
    server_version = "NavisAuthFixture/1.0"

    def log_message(self, fmt, *args):
        return

    def _json(self, payload, status=200):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            # Cancellation intentionally closes in-flight fixture requests.
            return

    def _bytes(self, data, content_type):
        start = 0
        end = len(data) - 1
        range_header = self.headers.get("Range")
        if range_header and range_header.startswith("bytes="):
            raw = range_header[6:].split(",", 1)[0]
            left, _, right = raw.partition("-")
            if left:
                start = min(int(left), len(data) - 1)
            if right:
                end = min(int(right), len(data) - 1)
        body = data[start : end + 1]
        self.send_response(206 if range_header else 200)
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(body)))
        if range_header:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.end_headers()
        try:
            if MEDIA_SECONDS <= 0 or not content_type.startswith("audio/"):
                self.wfile.write(body)
                return
            chunks = 20
            size = max(1, len(body) // chunks)
            for offset in range(0, len(body), size):
                self.wfile.write(body[offset : offset + size])
                self.wfile.flush()
                time.sleep(MEDIA_SECONDS / chunks)
        except (BrokenPipeError, ConnectionResetError):
            # A cancelled or paused download closes its transfer.
            return

    def _rescan(self, endpoint, query):
        phase = _rescan_phase()
        artists, albums, songs = _rescan_library(phase)
        ordered_albums = sorted(albums.values(), key=lambda album: album["id"])

        def page(items, size_key="size", offset_key="offset", default=500):
            offset = int(query.get(offset_key, ["0"])[0])
            size = int(query.get(size_key, [str(default)])[0])
            return items[offset : offset + size]

        if endpoint == "getScanStatus":
            self._json(_root(scanStatus={"scanning": False, "count": len(songs), "lastScan": RESCAN_SCANS[phase]}))
        elif endpoint == "getIndexes":
            self._json(_root(indexes={"lastModified": RESCAN_INDEXES[phase], "index": [{"name": "R", "artist": list(artists.values())}]}))
        elif endpoint == "getArtists":
            self._json(_root(artists={"index": [{"name": "R", "artist": list(artists.values())}]}))
        elif endpoint == "getArtist":
            artist = artists.get(query.get("id", [""])[0])
            if artist is None:
                self._json(_root(status="failed", error={"code": 70, "message": "Artist not found"}))
            else:
                mine = [a for a in ordered_albums if a["artistId"] == artist["id"]]
                self._json(_root(artist={**artist, "album": mine}))
        elif endpoint == "getAlbumList2":
            self._json(_root(albumList2={"album": page(ordered_albums)}))
        elif endpoint == "getAlbum":
            album = albums.get(query.get("id", [""])[0])
            if album is None:
                self._json(_root(status="failed", error={"code": 70, "message": "Album not found"}))
            else:
                mine = sorted((s for s in songs.values() if s["albumId"] == album["id"]), key=lambda s: s["track"])
                self._json(_root(album={**album, "song": mine}))
        elif endpoint == "search3":
            ordered_songs = sorted(songs.values(), key=lambda song: song["id"])
            self._json(_root(searchResult3={"song": page(ordered_songs, "songCount", "songOffset", 20)}))
        elif endpoint == "getStarred2":
            self._json(_root(starred2={"artist": [], "album": [], "song": []}))
        else:
            return False
        return True

    def do_GET(self):
        parsed = urlparse(self.path)
        endpoint = os.path.basename(parsed.path).removesuffix(".view")
        query = parse_qs(parsed.query)
        _log_request(endpoint, query)
        if RESCAN_ENABLED and self._rescan(endpoint, query):
            return
        if endpoint == "getArtists" and FAILURE_FLAG and os.path.exists(FAILURE_FLAG):
            self._json(
                {
                    "subsonic-response": {
                        "status": "failed",
                        "version": "1.16.1",
                        "error": {"code": 0, "message": "Fixture sync failure"},
                    }
                }
            )
            return
        if endpoint in {"stream", "download"}:
            self._bytes(SONG_AUDIO.get(query.get("id", [""])[0], AUDIO), "audio/wav")
            return
        if endpoint == "getCoverArt":
            self._bytes(PNG, "image/png")
            return
        if endpoint in {"star", "unstar", "setRating"}:
            if ANNOTATION_LOG:
                with open(ANNOTATION_LOG, "a", encoding="utf-8") as output:
                    output.write(json.dumps({"endpoint": endpoint, "parameters": {
                        key: query[key] for key in ("id", "albumId", "artistId", "rating") if key in query
                    }}) + "\n")
            self._json(_root())
            return
        if endpoint == "ping":
            self._json(_root())
            return
        if endpoint == "getOpenSubsonicExtensions":
            self._json(_root(openSubsonicExtensions={"openSubsonicExtension": []}))
            return
        if endpoint == "getArtists":
            time.sleep(0.8)
            self._json(_root(artists={"index": [{"name": "F", "artist": [ARTIST]}]}))
            return
        if endpoint == "getArtist":
            self._json(_root(artist={**ARTIST, "album": ARTIST_ALBUMS}))
            return
        if endpoint == "getAlbumList2":
            time.sleep(0.8)
            offset = int(query.get("offset", ["0"])[0])
            albums = ARTIST_ALBUMS if PARTIAL_ALBUM_FLAG or ALBUM_SONGS else [ALBUM]
            self._json(_root(albumList2={"album": albums if offset == 0 else []}))
            return
        if endpoint == "getAlbum":
            time.sleep(0.8)
            album_id = query.get("id", [""])[0]
            album = next((item for item in ALL_ALBUMS if item["id"] == album_id), None)
            if album is None:
                self._json(_root(status="failed", error={"code": 70, "message": "Album not found"}))
                return
            if (
                album_id == PARTIAL_ALBUM_ID
                and ALBUM_ERROR_FLAG
                and os.path.exists(ALBUM_ERROR_FLAG)
            ):
                # A server-side detail failure is not an incomplete response:
                # the promoted first catalog must not qualify as usable.
                self._json(
                    {"error": "Fixture album detail failure"}, status=500
                )
                return
            if album_id in ALBUM_SONGS:
                self._json(_root(album={**album, "song": ALBUM_SONGS[album_id]}))
                return
            song = SONG if album_id == ALBUM["id"] else {
                **SONG, "id": ALBUM_SONG_IDS.get(album_id, f"{album_id}-song"),
                "albumId": album_id, "album": album["name"],
            }
            songs = [song]
            if album_id == ALBUM["id"]:
                songs.extend(EXTRA_SONGS.values())
            if album_id == PARTIAL_ALBUM_ID and not os.path.exists(PARTIAL_ALBUM_FLAG):
                songs.append({**song, "id": f"{album_id}-song-2", "track": 2})
            self._json(_root(album={**album, "song": songs}))
            return
        if endpoint == "getSong":
            song_id = query.get("id", [""])[0]
            self._json(_root(song=EXTRA_SONGS.get(song_id, SONG)))
            return
        if endpoint == "getStarred2":
            self._json(_root(starred2={"artist": [], "album": [], "song": []}))
            return
        if endpoint == "getPlaylists":
            self._json(_root(playlists={"playlist": []}))
            return
        if endpoint == "search3":
            # The sync engine probes its supported empty-query bulk-song path
            # before falling back to authoritative getAlbum hydration. An
            # empty successful result is the compatible fixture response.
            self._json(_root(searchResult3={"song": []}))
            return
        if endpoint == "getIndexes":
            self._json(
                _root(
                    indexes={
                        "lastModified": INDEX_LAST_MODIFIED,
                        "index": [{"name": "F", "artist": [ARTIST]}],
                    }
                )
            )
            return
        if endpoint == "getAlbumInfo2":
            self._json(_root(albumInfo2={}))
            return
        if endpoint == "getArtistInfo2":
            self._json(_root(artistInfo2={"similarArtist": []}))
            return
        self._json(
            {
                "subsonic-response": {
                    "status": "failed",
                    "version": "1.16.1",
                    "error": {"code": 70, "message": "Not supported"},
                }
            }
        )


def main():
    global FAILURE_FLAG, PARTIAL_ALBUM_FLAG, ALBUM_ERROR_FLAG, MEDIA_SECONDS
    parser = argparse.ArgumentParser()
    parser.add_argument("--handshake", required=True)
    parser.add_argument("--failure-flag", required=True)
    parser.add_argument(
        "--scenario",
        choices=(
            "auth-lifecycle",
            "manual-discovery",
            "partial-album",
            "downloads",
            "genres",
            "rescan",
        ),
        default="auth-lifecycle",
    )
    parser.add_argument(
        "--song-count",
        type=int,
        default=8,
        help="Songs on the fixture album in downloads mode.",
    )
    parser.add_argument(
        "--song-rate",
        action="append",
        default=[],
        metavar="SONG_ID=HZ",
        help="Serve this downloads-mode song as a 4 s tone at another sample rate.",
    )
    parser.add_argument(
        "--song-tone",
        action="append",
        default=[],
        metavar="SONG_ID=HZ[:RATE[:SECONDS]]",
        help="Serve this downloads-mode song as a sine of HZ (sample rate RATE, "
        "default 22050; length SECONDS, default 4).",
    )
    parser.add_argument(
        "--song-wav",
        action="append",
        default=[],
        metavar="SONG_ID=CHANNELS:BITS",
        help="Serve this downloads-mode song as a 4 s, 22.05 kHz, 440 Hz WAV with "
        "this many channels and BITS 16 (integer) or 32 (float): another source "
        "format for AVQueuePlayer.",
    )
    parser.add_argument(
        "--media-seconds",
        type=float,
        default=0.0,
        help="Seconds each audio stream or download takes.",
    )
    parser.add_argument(
        "--omit-existing-artist-album",
        action="store_true",
        help="Return a partial getArtist album list in manual-discovery mode.",
    )
    parser.add_argument(
        "--distinct-covers",
        action="store_true",
        help="Give each extra song in downloads mode its own cover id.",
    )
    parser.add_argument(
        "--bind",
        default="127.0.0.1",
        help="Address to listen on (a LAN address exercises local-network access).",
    )
    parser.add_argument("--annotation-log")
    parser.add_argument(
        "--phase-file",
        help="Rescan mode: file read per request holding the library phase: A to H (see _rescan_library).",
    )
    parser.add_argument(
        "--rescan-albums",
        type=int,
        default=100,
        help="Rescan mode: albums in the library (the bulk song path needs 96).",
    )
    parser.add_argument(
        "--request-log",
        help="Append one JSON line per non-media request (endpoint and paging).",
    )
    parser.add_argument("--partial-album-flag")
    parser.add_argument(
        "--album-error-flag",
        help="While this file exists, the incomplete album's detail fails.",
    )
    args = parser.parse_args()
    global ANNOTATION_LOG, RESCAN_ENABLED, PHASE_FILE, REQUEST_LOG
    global RESCAN_ALBUM_COUNT, AUDIO
    ANNOTATION_LOG = args.annotation_log
    REQUEST_LOG = os.path.realpath(args.request_log) if args.request_log else ""
    FAILURE_FLAG = os.path.realpath(args.failure_flag)
    PARTIAL_ALBUM_FLAG = (
        os.path.realpath(args.partial_album_flag)
        if args.partial_album_flag is not None
        else ""
    )
    ALBUM_ERROR_FLAG = (
        os.path.realpath(args.album_error_flag)
        if args.album_error_flag is not None
        else ""
    )
    MEDIA_SECONDS = max(0.0, args.media_seconds)
    for entry in args.song_rate:
        song_id, _, rate = entry.partition("=")
        SONG_AUDIO[song_id] = _wav_bytes(rate=int(rate))
    for entry in args.song_tone:
        song_id, _, spec = entry.partition("=")
        parts = spec.split(":")
        hz, rate, seconds = parts[0], (parts[1:2] or ["22050"])[0], (parts[2:3] or ["4"])[0]
        SONG_AUDIO[song_id] = _wav_bytes(seconds=int(seconds), rate=int(rate), hz=int(hz))
        SONG_SECONDS[song_id] = int(seconds)
    for entry in args.song_wav:
        song_id, _, spec = entry.partition("=")
        channels, _, bits = spec.partition(":")
        SONG_AUDIO[song_id] = _wav_bytes(channels=int(channels), bits=int(bits))
    if args.scenario == "downloads":
        _configure_downloads_fixture(
            max(1, args.song_count), distinct_covers=args.distinct_covers
        )
    if args.scenario == "manual-discovery":
        _configure_manual_discovery_fixture(args.omit_existing_artist_album)
    if args.scenario == "genres":
        _configure_genres_fixture()
    if args.scenario == "rescan":
        if not args.phase_file:
            parser.error("--phase-file is required for rescan")
        RESCAN_ENABLED = True
        PHASE_FILE = os.path.realpath(args.phase_file)
        RESCAN_ALBUM_COUNT = max(20, args.rescan_albums)
        AUDIO = _wav_bytes(RESCAN_SONG_SECONDS)
    if args.scenario == "partial-album":
        if not PARTIAL_ALBUM_FLAG:
            parser.error("--partial-album-flag is required for partial-album")
        _configure_partial_album_fixture()
    server = ThreadingHTTPServer((args.bind, 0), Handler)
    os.makedirs(os.path.dirname(os.path.realpath(args.handshake)), exist_ok=True)
    with open(args.handshake, "w", encoding="utf-8") as output:
        json.dump(
            {
                # A wildcard bind is reachable, and best addressed, via loopback.
                "host": "127.0.0.1" if args.bind in ("", "0.0.0.0", "::") else args.bind,
                "port": server.server_port,
                "indexesLastModified": INDEX_LAST_MODIFIED,
            },
            output,
        )
    os.chmod(args.handshake, 0o600)
    server.serve_forever()


if __name__ == "__main__":
    main()
