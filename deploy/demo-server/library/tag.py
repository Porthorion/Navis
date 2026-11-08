"""Runs inside the container (see build-library.sh): copy, tag, ReplayGain, lyrics, covers, LICENSES.md.
usage: tag.py <lib-dir> <cache-dir> <out-dir>"""
import base64, colorsys, csv, hashlib, math, os, re, shutil, subprocess, sys
from collections import defaultdict
from mutagen.flac import FLAC, Picture
from mutagen.id3 import (APIC, ID3, TALB, TCMP, TCON, TDRC, TIT2, TPE1, TPE2, TPOS, TRCK, TXXX,
                         delete as id3_delete)
from mutagen.oggvorbis import OggVorbis

lib, cache, out = sys.argv[1:4]
REF = -18.0  # ReplayGain 2.0 reference, LUFS
rows = []
with open(f"{lib}/manifest.tsv", newline="") as fh:
    lines = [l for l in fh.read().split("\n") if l.strip()]
hdr = lines[0].lstrip("# ").split("\t")
for l in lines[1:]:
    rows.append(dict(zip(hdr, l.split("\t") + [""] * len(hdr))))

def loudness(paths):
    """Integrated loudness (LUFS) and true peak (linear) of the paths played back to back."""
    cmd = ["ffmpeg", "-nostats", "-hide_banner"]
    for p in paths: cmd += ["-i", p]
    fl = "".join(f"[{i}:a]aresample=48000[a{i}];" for i in range(len(paths)))
    fl += "".join(f"[a{i}]" for i in range(len(paths)))
    fl += f"concat=n={len(paths)}:v=0:a=1,ebur128=peak=true:framelog=quiet"
    err = subprocess.run(cmd + ["-filter_complex", fl, "-f", "null", "-"],
                         capture_output=True, text=True, check=True).stderr
    i = float(re.search(r"\bI:\s+(-?[\d.]+) LUFS", err).group(1))
    pk = re.search(r"Peak:\s+(-?[\d.]+|-inf) dBFS", err).group(1)
    return i, 0.0 if pk == "-inf" else 10 ** (float(pk) / 20)

def cover(album, artist, path):
    h = int(hashlib.sha1(album.encode()).hexdigest()[:6], 16) / 0xFFFFFF
    hx = lambda hue, s, v: "#%02x%02x%02x" % tuple(int(c * 255) for c in colorsys.hsv_to_rgb(hue % 1, s, v))
    subprocess.run(["magick", "-size", "800x800", f"gradient:{hx(h, .6, .75)}-{hx(h + .12, .8, .25)}",
        "(", "-background", "none", "-fill", "white", "-font", "DejaVu-Sans-Bold", "-size", "680x",
        "-gravity", "center", "-pointsize", "76", f"caption:{album}", ")", "-gravity", "center",
        "-geometry", "+0-40", "-composite",
        "(", "-background", "none", "-fill", "#ffffffcc", "-font", "DejaVu-Sans", "-size", "680x",
        "-gravity", "center", "-pointsize", "38", f"caption:{artist}", ")", "-gravity", "south",
        "-geometry", "+0+90", "-composite", "-strip", "-quality", "88", path], check=True)

albums = defaultdict(list)
for r in rows: albums[os.path.dirname(r["target"])].append(r)

for d, tracks in albums.items():
    os.makedirs(f"{out}/{d}", exist_ok=True)
    t0 = tracks[0]
    cover(t0["album"], t0["albumartist"], f"{out}/{d}/cover.jpg")
    img = open(f"{out}/{d}/cover.jpg", "rb").read()
    for r in tracks:
        dst = f"{out}/{r['target']}"
        shutil.copyfile(f"{cache}/{r['sha256']}", dst)
        r["lufs"], r["peak"] = loudness([dst])
    # album gain from the whole album played back to back, ordered by disc then track
    tracks.sort(key=lambda r: (int(r["disc"]), int(r["track"])))
    alb_lufs, _ = loudness([f"{out}/{r['target']}" for r in tracks])
    alb_peak = max(r["peak"] for r in tracks)
    for r in tracks:
        dst, ext = f"{out}/{r['target']}", r["target"].rsplit(".", 1)[1]
        rg = {"REPLAYGAIN_TRACK_GAIN": "%.2f dB" % (REF - r["lufs"]),
              "REPLAYGAIN_TRACK_PEAK": "%.6f" % r["peak"],
              "REPLAYGAIN_ALBUM_GAIN": "%.2f dB" % (REF - alb_lufs),
              "REPLAYGAIN_ALBUM_PEAK": "%.6f" % alb_peak}
        tn, dn = f"{r['track']}/{r['tracktotal']}", f"{r['disc']}/{r['disctotal']}"
        if ext == "mp3":
            id3_delete(dst)
            t = ID3()
            t.add(TIT2(encoding=3, text=r["title"])); t.add(TPE1(encoding=3, text=r["artist"]))
            t.add(TPE2(encoding=3, text=r["albumartist"])); t.add(TALB(encoding=3, text=r["album"]))
            t.add(TRCK(encoding=3, text=tn)); t.add(TPOS(encoding=3, text=dn))
            t.add(TDRC(encoding=3, text=r["year"])); t.add(TCON(encoding=3, text=r["genre"]))
            if r["compilation"]: t.add(TCMP(encoding=3, text="1"))
            for k, v in rg.items(): t.add(TXXX(encoding=3, desc=k, text=v))
            t.add(APIC(encoding=3, mime="image/jpeg", type=3, desc="Cover", data=img))
            t.save(dst, v2_version=4)
        else:
            f = FLAC(dst) if ext == "flac" else OggVorbis(dst)
            f.delete()
            if ext == "flac": f.clear_pictures()
            f.update({"TITLE": r["title"], "ARTIST": r["artist"], "ALBUMARTIST": r["albumartist"],
                      "ALBUM": r["album"], "TRACKNUMBER": r["track"], "TRACKTOTAL": r["tracktotal"],
                      "DISCNUMBER": r["disc"], "DISCTOTAL": r["disctotal"], "DATE": r["year"],
                      "GENRE": r["genre"], **rg})
            if r["compilation"]: f["COMPILATION"] = "1"
            p = Picture(); p.type, p.mime, p.data = 3, "image/jpeg", img
            if ext == "flac": f.add_picture(p)
            else: f["METADATA_BLOCK_PICTURE"] = base64.b64encode(p.write()).decode()
            f.save()
        if r["lyrics"]:
            shutil.copyfile(f"{lib}/lyrics/{r['lyrics']}", dst.rsplit(".", 1)[0] + ".lrc")
        print("  %-80s track %6.2f dB  album %6.2f dB" % (r["target"][-80:], REF - r["lufs"], REF - alb_lufs))

# LICENSES.md
with open(f"{out}/LICENSES.md", "w") as m:
    m.write("# Demo library licences\n\nEvery track is CC0 1.0 or public domain for both the composition and the "
            "recording (no BY, NC or ND material). Licence evidence was read on each source page on 2026-11-08. "
            "sha256 is of the downloaded source file.\n\nThe generated covers (`cover.jpg`, also embedded) and "
            "the synced-lyrics timings (`.lrc`) are original work of this project and dedicated CC0 1.0.\n")
    for d, tracks in albums.items():
        t0 = tracks[0]
        m.write(f"\n## {t0['albumartist']} - {t0['album']}\n\n| Artist | Title | Source page | File URL | Licence | sha256 |\n|---|---|---|---|---|---|\n")
        for r in tracks:
            m.write(f"| {r['artist']} | {r['title']} | <{r['page']}> | <{r['url']}> | {r['licence']} | `{r['sha256']}` |\n")
print("%d files, %d albums" % (len(rows), len(albums)))
