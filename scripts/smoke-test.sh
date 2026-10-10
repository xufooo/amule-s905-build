#!/usr/bin/env bash
# Run in the build container with the staged bundle; never uses a real profile.
set -euo pipefail
AP="${1:-/work/stage/opt/aMule}"
PROFILE="$(mktemp -d)"
PID=
cleanup() {
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$PROFILE"
}
trap cleanup EXIT
umask 077
mkdir -p "$PROFILE/Incoming" "$PROFILE/Temp"
cat > "$PROFILE/amule.conf" <<EOF
[eMule]
AppVersion=3.1.0
IncomingDir=$PROFILE/Incoming
TempDir=$PROFILE/Temp
Autoconnect=0
ConnectToKad=0
ConnectToED2K=0
UPnPEnabled=0
GeoIPEnabled=0
GeoIPAutoUpdate=0
IPFilterAutoLoad=0
NewVersionCheck=0
[ExternalConnect]
AcceptExternalConnections=1
ECAddress=127.0.0.1
ECPort=4712
ECPassword=098f6bcd4621d373cade4e832627b4f6
[AmuleApi]
Enabled=1
HttpPort=4713
BindAddress=127.0.0.1
Path=$AP/amuleapi
[MediaMetadata]
Enabled=0
EOF
cat > "$PROFILE/amuleapi.conf" <<EOF
[Server]
BindAddress=127.0.0.1
Port=4713
StaticRoot=$AP/share/amule/amuleapi-static
EOF
"$AP/amuleapi" --config-dir="$PROFILE" --set-admin-pass=ci-smoke-only
"$AP/amuled" --config-dir="$PROFILE" --disable-fatal > "$PROFILE/core.log" 2>&1 &
PID=$!
ready=0
for ((attempt=0; attempt<60; attempt++)); do
  if curl -fsS --max-time 2 http://127.0.0.1:4713/api/v1/health > "$PROFILE/health.json" 2>/dev/null && \
     python3 -c 'import json,sys; h=json.load(open(sys.argv[1])); sys.exit(not (h["ec_connected"] and h["snapshot_ready"]))' "$PROFILE/health.json"; then
    ready=1
    break
  fi
  if ! kill -0 "$PID" 2>/dev/null; then break; fi
  sleep 1
done
if [ "$ready" != 1 ]; then
  cat "$PROFILE/core.log"
  cat "$PROFILE/amuleapi.log" 2>/dev/null || true
  exit 1
fi
curl -fsS --max-time 5 http://127.0.0.1:4713/ > "$PROFILE/index.html"
grep -qi '<html' "$PROFILE/index.html"
curl -fsS --max-time 5 -c "$PROFILE/cookies" \
  -H 'Content-Type: application/json' \
  -d '{"password":"ci-smoke-only"}' \
  http://127.0.0.1:4713/api/v1/auth/login > "$PROFILE/login.json"
curl -fsS --max-time 5 -b "$PROFILE/cookies" \
  http://127.0.0.1:4713/api/v1/status > "$PROFILE/status.json"
python3 -m json.tool "$PROFILE/status.json" > /dev/null
echo 'PASS: amuled starts, amuleapi connects over EC, Web UI serves, login and status work.'
