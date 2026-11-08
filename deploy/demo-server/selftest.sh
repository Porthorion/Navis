#!/usr/bin/env bash
# End-to-end check of the demo stack on local docker: real compose.yaml,
# bootstrap.sh, and nginx with the shipped location config in front.
# Usage: deploy/demo-server/selftest.sh   (needs docker, ffmpeg, curl, jq, openssl)
# Library mode: DEMO_TEST_MUSIC=<dir built by library/build-library.sh> selftest.sh
#   scans that library (read-only) instead of three sine tracks and checks it.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker info >/dev/null 2>&1 || { echo "docker unavailable" >&2; exit 2; }
for c in ffmpeg curl jq openssl; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 2; }; done

T="$(mktemp -d)"; NG="navis-demo-selftest-nginx-$$"; PROJ="navis-demo-selftest-$$"
APP_PORT=14535; PROXY_PORT=14536; BOOT_PORT=14537; FAILS=0
cleanup() {
  ( cd "$T" 2>/dev/null && docker compose down -v >/dev/null 2>&1 ) || true
  docker rm -f "$NG" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

mkdir -p "$T"/{data,seed,master,music/Test\ Artist/Test\ Album}
cp "$SRC"/{compose.yaml,entrypoint.sh,bootstrap.sh} "$T"/
MUSIC="$T/music"; SONG=Sine
if [[ -n "${DEMO_TEST_MUSIC:-}" ]]; then MUSIC="$(cd "$DEMO_TEST_MUSIC" && pwd)"; SONG=Daisy; fi
for i in $([[ -n "${DEMO_TEST_MUSIC:-}" ]] || echo 1 2 3); do
  ffmpeg -loglevel error -f lavfi -i "sine=frequency=$((300 + i * 100)):duration=5" \
    -metadata title="Sine Song $i" -metadata artist="Test Artist" -metadata album="Test Album" \
    -metadata track="$i" "$T/music/Test Artist/Test Album/0$i.flac"
done
RPASS="$(openssl rand -hex 8)"
cat > "$T/.env" <<ENV
COMPOSE_PROJECT_NAME=$PROJ
DEMO_UID=$(id -u)
DEMO_GID=$(id -g)
DEMO_PORT=$APP_PORT
DEMO_BOOT_PORT=$BOOT_PORT
DEMO_DATA_DIR=$T/data
DEMO_SEED_DIR=$T/seed
DEMO_MASTER_DIR=$T/master
DEMO_MUSIC_DIR=$MUSIC
ND_PASSWORDENCRYPTIONKEY=$(openssl rand -hex 16)
DEMO_ADMIN_CREDS_FILE=$T/admin-credentials
DEMO_REVIEWER_USER=reviewer
DEMO_REVIEWER_PASSWORD=$RPASS
ENV

echo "== bootstrap"
( cd "$T" && ./bootstrap.sh ) 2>&1 | sed 's/^/   /'
[[ -s "$T/seed/navidrome.db" ]] || { fail "seed exported"; exit 1; }
check "seed is mode 600" test "$(stat -c %a "$T/seed/navidrome.db")" = 600
check "admin creds file mode 600" test "$(stat -c %a "$T/admin-credentials")" = 600
check "master seed is mode 600" test "$(stat -c %a "$T/master/navidrome.db")" = 600
AU="$(sed -n 's/^user=//p' "$T/admin-credentials")"; AP="$(sed -n 's/^password=//p' "$T/admin-credentials")"
check "master seed holds the admin (control)" grep -aq "$AU" "$T/master/navidrome.db"
check "public seed holds no admin" bash -c "! grep -aq '$AU' '$T/seed/navidrome.db'"

echo "== nginx"
mkdir "$T/nginx"
cp "$SRC"/nginx/demo-location.conf "$T/nginx/"
sed -i "s#127.0.0.1:4535#127.0.0.1:$APP_PORT#" "$T/nginx/demo-location.conf"   # test-time only
cat > "$T/nginx/nginx.conf" <<NGX
events {}
http {
  error_log /dev/stderr info;
  include /etc/nginx/test/http-zone.conf;
  server {
    listen 127.0.0.1:$PROXY_PORT;
    include /etc/nginx/test/demo-location.conf;
    location /probe/ { proxy_pass http://127.0.0.1:1; }   # control: a logged error outside /demo
  }
}
NGX
cp "$SRC"/nginx/http-zone.conf "$T/nginx/"
docker run -d --name "$NG" --network host -v "$T/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$T/nginx:/etc/nginx/test:ro" nginx:alpine >/dev/null
for _ in $(seq 1 20); do curl -s -o /dev/null "http://127.0.0.1:$PROXY_PORT/demo/" && break; sleep 0.5; done

P="http://127.0.0.1:$PROXY_PORT/demo"
Q="u=reviewer&p=$RPASS&v=1.16.1&c=selftest&f=json"
rest() { curl -s "$P/rest/$1?$Q${2:+&$2}"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "== assertions"
check "reviewer ping ok" test "$(rest ping | jq -r '."subsonic-response".status')" = ok
SID="$(rest search3 "query=$SONG" | jq -r '."subsonic-response".searchResult3.song[0].id // empty')"
check "search3 finds a song" test -n "$SID"
check "stream.view returns audio" test "$(curl -s -o /dev/null -w '%{content_type}' "$P/rest/stream.view?$Q&id=$SID")" = audio/flac
check "stream.view honours Range (206)" test "$(code -H 'Range: bytes=0-99' "$P/rest/stream.view?$Q&id=$SID")" = 206
check "getCoverArt answers 200" test "$(code "$P/rest/getCoverArt.view?$Q&id=$SID")" = 200
check "API responses carry no Set-Cookie" bash -c "! curl -s -D- -o /dev/null '$P/rest/ping?$Q' | grep -qi ^set-cookie"
check "download.view works" test "$(code "$P/rest/download.view?$Q&id=$SID")" = 200
if [[ -n "${DEMO_TEST_MUSIC:-}" ]]; then
  echo "== library"
  ALB="$(rest getAlbumList2 'type=alphabeticalByName&size=50' | jq -c '."subsonic-response".albumList2.album')"
  check "6 albums" test "$(jq length <<<"$ALB")" = 6
  aid() { jq -r --arg n "$1" '.[] | select(.name==$n) | .id' <<<"$ALB"; }
  songs() { rest getAlbum "id=$(aid "$1")" | jq -c '."subsonic-response".album'; }
  check "compilation flagged" test "$(songs 'Public Domain Voices' | jq -r '.isCompilation')" = true
  check "compilation keeps 3 track artists" test "$(songs 'Public Domain Voices' | jq '[.song[].artist] | unique | length')" = 3
  check "Komiku has 2 discs" test "$(songs "It's time for adventure !" | jq '[.song[].discNumber] | unique | length')" = 2
  check "Komiku has 12 songs" test "$(songs "It's time for adventure !" | jq '.song | length')" = 12
  check "HYPER METAL has album ReplayGain" test "$(songs 'HYPER METAL !' | jq '.song[0].replayGain.albumGain')" != null
  LY="$(rest getLyricsBySongId "id=$SID" | jq -c '."subsonic-response".lyricsList.structuredLyrics[0]')"
  echo "   lyrics: $(jq -c '[.synced, (.line | length), .line[0], .line[-1]]' <<<"$LY")"
  check "Daisy Bell lyrics are synced with 6 lines" test "$(jq -c '[.synced, (.line | length)]' <<<"$LY")" = '[true,6]'
  CID="$(aid 'HYPER METAL !')"
  check "getCoverArt returns our cover.jpg" cmp <(curl -s "$P/rest/getCoverArt.view?$Q&id=$CID") "$MUSIC/Loyalty Freak Music/HYPER METAL/cover.jpg"
fi
for path in app/ auth/login api/user ""; do
  check "/demo/$path is 404" test "$(code "$P/$path")" = 404
done
check "POST /demo/auth/login is 404" test "$(code -X POST -d '{}' "$P/auth/login")" = 404
for m in changePassword changePassword.view createUser deleteUser.view createShare getShares jukeboxControl updateInternetRadioStation; do
  check "$m is 403" test "$(code -X POST -d "$Q" "$P/rest/$m")" = 403
done
check "reviewer is not admin" test "$(rest getUser username=reviewer | jq -r '."subsonic-response".user.adminRole')" = false
check "/demo/api/user (native API) unreachable via proxy" test "$(code "$P/api/user")" = 404

echo "== log hygiene, limits, lockout"
curl -s -o /dev/null "http://127.0.0.1:$PROXY_PORT/probe/x"
check "control: nginx error log works outside /demo" bash -c "docker logs $NG 2>&1 | grep -q probe"
curl -s -o /dev/null --limit-rate 1k --max-time 1 "$P/rest/stream.view?$Q&id=$SID" || true   # canceled mid-stream
curl -s -o /dev/null --max-time 1 "$P/rest/getCoverArt.view?$Q&id=$SID&size=1" || true
sleep 1
check "nginx error log has no /demo lines" bash -c "! docker logs $NG 2>&1 | grep -q demo"
for i in $(seq 10); do curl -s -o /dev/null "$P/rest/ping?u=reviewer&p=wrong$i&v=1.16.1&c=t&f=json"; done
curl -s -o /dev/null "$P/rest/ping?u=lockprobe-xyz&p=wrong&v=1.16.1&c=t&f=json"
check "reviewer works after 10 bad logins (no lockout)" test "$(rest ping | jq -r '."subsonic-response".status')" = ok
check "Navidrome log has no typed username (error level)" bash -c "! (cd '$T' && docker compose logs navidrome 2>&1 | grep -q lockprobe-xyz)"
check "control: startup errors still logged" bash -c "cd '$T' && docker compose logs navidrome 2>&1 | grep -q 'No admin user found'"
CODES="$(for i in $(seq 8); do curl -s -o /dev/null -w '%{http_code}\n' --limit-rate 1k --max-time 3 "$P/rest/stream.view?$Q&id=$SID" & done; wait)"
check "7th+ parallel stream per IP gets 429" bash -c "grep -q 429 <<<'$CODES'"
CODES="$(for i in $(seq 25); do curl -s -o /dev/null -w '%{http_code}\n' "$P/rest/getCoverArt.view?$Q&id=$SID" & done; wait)"
check "25 parallel cover requests are not limited" bash -c "! grep -v 200 <<<'$CODES' | grep -q ."
CID_="$(cd "$T" && docker compose ps -q navidrome)"
check "resource limits applied" test "$(docker inspect -f '{{.HostConfig.Memory}} {{.HostConfig.PidsLimit}} {{.HostConfig.NanoCpus}}' "$CID_")" = "536870912 200 1000000000"
check "compose refuses an empty ND_PASSWORDENCRYPTIONKEY" bash -c "cd '$T' && ! ND_PASSWORDENCRYPTIONKEY= docker compose config >/dev/null 2>&1"
IMG="$(sed -n 's/^ *image: //p' "$T/compose.yaml")"
for kind in empty text; do
  mkdir -p "$T/badseed-$kind"; if [[ $kind == text ]]; then echo "not a database" > "$T/badseed-$kind/navidrome.db"; else : > "$T/badseed-$kind/navidrome.db"; fi
  check "entrypoint refuses a $kind seed" bash -c "! docker run --rm --entrypoint /bin/sh -v '$T/badseed-$kind:/seed:ro' -v '$T/entrypoint.sh:/e.sh:ro' '$IMG' /e.sh >/dev/null 2>&1"
done

echo "== reset on restart"
rest star "id=$SID" >/dev/null
check "starred before restart" test "$(rest getStarred2 | jq '."subsonic-response".starred2.song | length')" = 1
( cd "$T" && docker compose restart >/dev/null 2>&1 )
for _ in $(seq 1 60); do [[ "$(rest ping | jq -r '."subsonic-response".status' 2>/dev/null)" == ok ]] && break; sleep 1; done
admin_ping() { curl -s "$P/rest/ping?u=$AU&p=$AP&v=1.16.1&c=t&f=json" | jq -r '."subsonic-response".status'; }
check "admin ping fails after restart" test "$(admin_ping)" = failed
check "getUsers shows no admin" test "$(rest getUsers | jq '[(."subsonic-response".users.user // [])[] | select(.adminRole==true)] | length')" = 0
check "getUser for the admin name finds nobody" test "$(rest getUser "username=$AU" | jq -r '."subsonic-response".status')" = failed
check "POST /auth/createAdmin refused on the app port" test "$(code -X POST -H 'Content-Type: application/json' -d '{"username":"x","password":"yyyyyyyy"}' "http://127.0.0.1:$APP_PORT/demo/auth/createAdmin")" = 403
check "reviewer signs in after restart" test "$(rest ping | jq -r '."subsonic-response".status')" = ok
check "getStarred2 empty after restart" test "$(rest getStarred2 | jq '(."subsonic-response".starred2.song // []) | length')" = 0
check "reviewer still stars after restart" test "$(rest star "id=$SID" | jq -r '."subsonic-response".status')" = ok
check "reviewer still streams after restart (206)" test "$(code -H 'Range: bytes=0-99' "$P/rest/stream.view?$Q&id=$SID")" = 206
if [[ -n "${DEMO_TEST_MUSIC:-}" ]]; then
  check "reviewer still gets lyrics after restart" test "$(rest getLyricsBySongId "id=$SID" | jq '."subsonic-response".lyricsList.structuredLyrics | length')" -ge 1
fi
check "container healthy" bash -c "for _ in \$(seq 1 40); do [ \"\$(docker inspect -f '{{.State.Health.Status}}' \$(cd '$T' && docker compose ps -q navidrome))\" = healthy ] && exit 0; sleep 2; done; exit 1"

echo "== rotate-reviewer"
NEW="$(openssl rand -hex 8)"
( cd "$T" && DEMO_REVIEWER_PASSWORD="$NEW" ./bootstrap.sh rotate-reviewer ) 2>&1 | sed 's/^/   /'
Q="u=reviewer&p=$NEW&v=1.16.1&c=selftest&f=json"
for _ in $(seq 1 60); do [[ "$(rest ping | jq -r '."subsonic-response".status' 2>/dev/null)" == ok ]] && break; sleep 1; done
check "new password works after rotation" test "$(rest ping | jq -r '."subsonic-response".status')" = ok
check "admin ping still fails after rotation" test "$(admin_ping)" = failed
check "public seed still holds no admin after rotation" bash -c "! grep -aq '$AU' '$T/seed/navidrome.db'"
check "old password rejected" test "$(curl -s "$P/rest/ping?u=reviewer&p=$RPASS&v=1.16.1&c=t&f=json" | jq -r '."subsonic-response".status')" = failed

echo "== failed rotation leaves the public service safe"
SUMS="$(sha256sum "$T/seed/navidrome.db" "$T/master/navidrome.db")"
cp "$T/admin-credentials" "$T/admin-credentials.good"; printf 'user=%s\npassword=wrong\n' "$AU" > "$T/admin-credentials"
if ( cd "$T" && DEMO_REVIEWER_PASSWORD=whatever ./bootstrap.sh rotate-reviewer ) >"$T/fail.log" 2>&1; then fail "rotation with bad admin creds exits non-zero"; else pass "rotation with bad admin creds exits non-zero"; fi
mv "$T/admin-credentials.good" "$T/admin-credentials"
check "failed rotation leaves both seeds untouched" test "$SUMS" = "$(sha256sum "$T/seed/navidrome.db" "$T/master/navidrome.db")"
for _ in $(seq 1 60); do [[ "$(rest ping | jq -r '."subsonic-response".status' 2>/dev/null)" == ok ]] && break; sleep 1; done
check "public service back in normal mode (reviewer ping)" test "$(rest ping | jq -r '."subsonic-response".status')" = ok
check "admin ping fails through nginx after the failure" test "$(admin_ping)" = failed
check "admin ping fails on the app port after the failure" test "$(curl -s "http://127.0.0.1:$APP_PORT/demo/rest/ping?u=$AU&p=$AP&v=1.16.1&c=t&f=json" | jq -r '."subsonic-response".status')" = failed
check "no bootstrap container left" test -z "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJ-boot")"
check "bootstrap port is closed" test "$(code "http://127.0.0.1:$BOOT_PORT/demo/ping")" = 000
rest star "id=$SID" >/dev/null
( cd "$T" && docker compose restart >/dev/null 2>&1 )
for _ in $(seq 1 60); do [[ "$(rest ping | jq -r '."subsonic-response".status' 2>/dev/null)" == ok ]] && break; sleep 1; done
check "restart still resets after the failure" test "$(rest getStarred2 | jq '(."subsonic-response".starred2.song // []) | length')" = 0

echo "== rescan (no reviewer vars in .env, rotated password kept)"
sed -i '/^DEMO_REVIEWER_/d' "$T/.env"
( cd "$T" && ./bootstrap.sh rescan ) 2>&1 | sed 's/^/   /'
for _ in $(seq 1 60); do [[ "$(rest ping | jq -r '."subsonic-response".status' 2>/dev/null)" == ok ]] && break; sleep 1; done
check "rotated password survives rescan" test "$(rest ping | jq -r '."subsonic-response".status')" = ok
check "songs still indexed after rescan" test "$(rest search3 "query=$SONG" | jq '."subsonic-response".searchResult3.song | length')" -ge 1
check "admin ping fails after rescan" test "$(admin_ping)" = failed

echo
if ((FAILS)); then echo "RESULT: $FAILS assertion(s) FAILED"; exit 1; fi
echo "RESULT: all assertions passed"
