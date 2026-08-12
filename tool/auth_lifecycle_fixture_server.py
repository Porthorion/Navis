#!/usr/bin/env python3
"""Small deterministic Subsonic fixture for auth lifecycle diagnostics."""

import argparse
import base64
import io
import json
import math
import os
import struct
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


def _wav_bytes() -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(22050)
        frames = bytearray()
        for index in range(22050 * 4):
            sample = int(5000 * math.sin(2 * math.pi * 440 * index / 22050))
            frames.extend(struct.pack("<h", sample))
        wav.writeframes(frames)
    return output.getvalue()


AUDIO = _wav_bytes()
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)
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
    "genre": "Diagnostics",
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
INDEX_LAST_MODIFIED = 1780000000000
FAILURE_FLAG = ""


def _configure_manual_discovery_fixture(omit_existing_artist_album=False):
    """Expose a new album without changing the artist-index cursor.

    This intentionally models the Navidrome/Subsonic gap that Navis must
    cover with its bounded newest-album discovery: the artist collection is
    unchanged, but an already-known artist has received a new album.
    """
    global ALBUM, ARTIST, ARTIST_ALBUMS, INDEX_LAST_MODIFIED, SONG
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
        "genre": "Diagnostics",
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
        "genre": "Diagnostics",
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
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        endpoint = os.path.basename(parsed.path).removesuffix(".view")
        query = parse_qs(parsed.query)
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
            self._bytes(AUDIO, "audio/wav")
            return
        if endpoint == "getCoverArt":
            self._bytes(PNG, "image/png")
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
            self._json(_root(albumList2={"album": [ALBUM] if offset == 0 else []}))
            return
        if endpoint == "getAlbum":
            time.sleep(0.8)
            self._json(_root(album={**ALBUM, "song": [SONG]}))
            return
        if endpoint == "getSong":
            self._json(_root(song=SONG))
            return
        if endpoint == "getGenres":
            self._json(
                _root(
                    genres={
                        "genre": [
                            {"name": "Diagnostics", "songCount": 1, "albumCount": 1}
                        ]
                    }
                )
            )
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
    global FAILURE_FLAG
    parser = argparse.ArgumentParser()
    parser.add_argument("--handshake", required=True)
    parser.add_argument("--failure-flag", required=True)
    parser.add_argument(
        "--scenario",
        choices=("auth-lifecycle", "manual-discovery"),
        default="auth-lifecycle",
    )
    parser.add_argument(
        "--omit-existing-artist-album",
        action="store_true",
        help="Return a partial getArtist album list in manual-discovery mode.",
    )
    args = parser.parse_args()
    FAILURE_FLAG = os.path.realpath(args.failure_flag)
    if args.scenario == "manual-discovery":
        _configure_manual_discovery_fixture(args.omit_existing_artist_album)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    os.makedirs(os.path.dirname(os.path.realpath(args.handshake)), exist_ok=True)
    with open(args.handshake, "w", encoding="utf-8") as output:
        json.dump(
            {
                "port": server.server_port,
                "indexesLastModified": INDEX_LAST_MODIFIED,
            },
            output,
        )
    os.chmod(args.handshake, 0o600)
    server.serve_forever()


if __name__ == "__main__":
    main()
