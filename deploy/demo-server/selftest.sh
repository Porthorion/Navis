#!/usr/bin/env bash
# End-to-end check of the demo stack on local docker: real compose.yaml,
# bootstrap.sh, and nginx with the shipped location config in front.
# Usage: deploy/demo-server/selftest.sh   (needs docker, ffmpeg, curl, jq, openssl)
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker info >/dev/null 2>&1 || { echo "docker unavailable" >&2; exit 2; }
for c in ffmpeg curl jq openssl; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 2; }; done

T="$(mktemp -d)"; NG="navis-demo-selftest-nginx-$$"; PROJ="navis-demo-selftest-$$"
APP_PORT=14535; PROXY_PORT=14536; FAILS=0
cleanup() {
  ( cd "$T" 2>/dev/null && docker compose down -v >/dev/null 2>&1 ) || true
  docker rm -f "$NG" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

mkdir -p "$T"/{data,seed,music/Test\ Artist/Test\ Album}
cp "$SRC"/{compose.yaml,entrypoint.sh,bootstrap.sh} "$T"/
for i in 1 2 3; do
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
DEMO_DATA_DIR=$T/data
DEMO_SEED_DIR=$T/seed
DEMO_MUSIC_DIR=$T/music
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

echo "== nginx"
mkdir "$T/nginx"
cp "$SRC"/nginx/demo-location.conf "$T/nginx/"
sed -i "s#127.0.0.1:4535#127.0.0.1:$APP_PORT#" "$T/nginx/demo-location.conf"   # test-time only
cat > "$T/nginx/nginx.conf" <<NGX
events {}
http {
  include /etc/nginx/test/http-zone.conf;
  server {
    listen 127.0.0.1:$PROXY_PORT;
    include /etc/nginx/test/demo-location.conf;
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
SID="$(rest search3 'query=Sine' | jq -r '."subsonic-response".searchResult3.song[0].id // empty')"
check "search3 finds a song" test -n "$SID"
check "stream.view returns audio" test "$(curl -s -o /dev/null -w '%{content_type}' "$P/rest/stream.view?$Q&id=$SID")" = audio/flac
check "stream.view honours Range (206)" test "$(code -H 'Range: bytes=0-99' "$P/rest/stream.view?$Q&id=$SID")" = 206
check "getCoverArt answers 200" test "$(code "$P/rest/getCoverArt.view?$Q&id=$SID")" = 200
check "download.view works" test "$(code "$P/rest/download.view?$Q&id=$SID")" = 200
for path in app/ auth/login api/user ""; do
  check "/demo/$path is 404" test "$(code "$P/$path")" = 404
done
check "POST /demo/auth/login is 404" test "$(code -X POST -d '{}' "$P/auth/login")" = 404
for m in changePassword changePassword.view createUser deleteUser.view createShare getShares jukeboxControl updateInternetRadioStation; do
  check "$m is 403" test "$(code -X POST -d "$Q" "$P/rest/$m")" = 403
done
check "reviewer is not admin" test "$(rest getUser username=reviewer | jq -r '."subsonic-response".user.adminRole')" = false
check "/demo/api/user (native API) unreachable via proxy" test "$(code "$P/api/user")" = 404

echo "== reset on restart"
rest star "id=$SID" >/dev/null
check "starred before restart" test "$(rest getStarred2 | jq '."subsonic-response".starred2.song | length')" = 1
( cd "$T" && docker compose restart >/dev/null 2>&1 )
for _ in $(seq 1 60); do [[ "$(rest ping | jq -r '."subsonic-response".status' 2>/dev/null)" == ok ]] && break; sleep 1; done
check "reviewer signs in after restart" test "$(rest ping | jq -r '."subsonic-response".status')" = ok
check "getStarred2 empty after restart" test "$(rest getStarred2 | jq '(."subsonic-response".starred2.song // []) | length')" = 0
check "container healthy" bash -c "for _ in \$(seq 1 40); do [ \"\$(docker inspect -f '{{.State.Health.Status}}' \$(cd '$T' && docker compose ps -q navidrome))\" = healthy ] && exit 0; sleep 2; done; exit 1"

echo "== rotate-reviewer"
NEW="$(openssl rand -hex 8)"
( cd "$T" && DEMO_REVIEWER_PASSWORD="$NEW" ./bootstrap.sh rotate-reviewer ) 2>&1 | sed 's/^/   /'
Q="u=reviewer&p=$NEW&v=1.16.1&c=selftest&f=json"
for _ in $(seq 1 60); do [[ "$(rest ping | jq -r '."subsonic-response".status' 2>/dev/null)" == ok ]] && break; sleep 1; done
check "new password works after rotation" test "$(rest ping | jq -r '."subsonic-response".status')" = ok
check "old password rejected" test "$(curl -s "$P/rest/ping?u=reviewer&p=$RPASS&v=1.16.1&c=t&f=json" | jq -r '."subsonic-response".status')" = failed

echo
if ((FAILS)); then echo "RESULT: $FAILS assertion(s) FAILED"; exit 1; fi
echo "RESULT: all assertions passed"
