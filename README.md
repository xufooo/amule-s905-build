# aMule 3.1.0 for S905 / Ubuntu 18.04 arm64

Builds `amuled`, **`amuleapi` with the new Web UI**, legacy `amuleweb`, and
`amulecmd` on a native ARM64 GitHub Actions runner inside Ubuntu 18.04.
The target is a Phicomm N1 / Cortex-A53 running glibc 2.27, with downloads
on a separate mounted disk and services running as `pi`.

## Features and optimisation

| Item | Build / runtime choice |
| --- | --- |
| S905 CPU | `-mcpu=cortex-a53`; no `-march=native` or forced optional crypto extensions |
| Release optimisation | aMule Release (`-O3`), wxBase release; Crypto++ explicitly `-O3 -DNDEBUG` |
| Link | LTO with a non-LTO fallback; function/data sections and linker garbage collection |
| Dependencies | Shared wxBase + network, without GTK/X11/OpenGL; pinned wx epoll fix retained |
| New Web / API | `BUILD_AMULEAPI=ON`; REST, live SSE updates, categories and shared-folder tree |
| GeoIP | `ENABLE_IP2COUNTRY=ON`; system `libmaxminddb`, DB-IP auto-update recommended |
| Media metadata | Core support included; install `ffmpeg` for `ffprobe`, which reads metadata without transcoding |
| File I/O | `ENABLE_MMAP=ON` includes the option; `MMapEnabled=0` remains the runtime baseline |
| Mature core features | Endgame, recursive shares, filesystem watching and EC encryption supported |
| UPnP / translations | Enabled; Ubuntu's UPnP runtime libraries retained |
| Backtraces | `ENABLE_BFD=OFF`; avoids libbfd, retains upstream addr2line fallback |
| Experimental features | IPv6 admission, uTP, Kad 0x0a and Kad node protection explicitly OFF |

The new core's transfer pipeline, startup scanning and EC cache improvements
do not require extra compiler switches. Enabling every experimental option,
`-Ofast`, or globally requiring ARM crypto extensions is not a substitute for
measuring this CPU and workload. No benchmark speedup is claimed.

Build verification fails on missing binaries/libraries, wrong architecture,
unexpected GUI dependencies, missing frontend assets or missing GeoIP support.
An isolated profile then tests core startup, EC connection, Web serving,
password login and authenticated status. It never reads the box's real profile.
`build-features.txt` records the actual switches, including whether LTO survived.

## Build

Run **Actions → aMule build — Ubuntu 18.04 arm64 → Run workflow**.
Artifacts are uploaded after verification. `publish_release` defaults to false;
turn it on to publish a new uniquely named release without deleting older builds.
Dependency versions and the wxWidgets fix are pinned in `scripts/build.sh`.

## Upgrade an existing N1

Keep `/home/pi/.aMule` intact: it contains credentials, identity/credits,
download state, categories and selected share roots. The tarball contains only
`/opt/aMule`; it does not install a replacement user profile.

First install runtime dependencies from your existing working Ubuntu sources:

```bash
sudo apt update
sudo apt install -y libglib2.0-0 libcurl4 libreadline7 libpng16-16 \
  zlib1g libupnp6 libmaxminddb0 ffmpeg
```

Ubuntu 18.04 is EOL; if apt sources no longer work, repair those separately.
Do not replace a working mirror just to install this bundle.

```bash
sudo systemctl stop amuleweb amuled
# Keep private profile and program backups for rollback.
sudo install -d -m 700 /var/backups/amule
sudo tar czf "/var/backups/amule/profile-$(date +%Y%m%d-%H%M%S).tar.gz" \
  -C /home/pi .aMule
sudo tar czf "/var/backups/amule/program-$(date +%Y%m%d-%H%M%S).tar.gz" \
  -C /opt aMule
sha256sum -c aMule-3.1.0-ubuntu18.04-arm64.tar.gz.sha256
sudo tar xzf aMule-3.1.0-ubuntu18.04-arm64.tar.gz -C /
```

While the core is stopped, merge the selected values from
[`config/s905-recommended.ini`](config/s905-recommended.ini) into the existing
`amule.conf`. **The overlay is not a complete config: never copy it over the
profile.** It deliberately leaves ports, passwords, connection limits, paths,
categories and sharing lists untouched. Clear obsolete GeoIP download URLs if
switching from a legacy `.dat` database to `GeoIPSource=dbip`.

The suggested 10 GiB free-space floor is for the N1's large download disk;
adjust it for a smaller disk. Upload/download limits remain as configured
(including unlimited upload with router SQM). Router SQM does not itself assign
separate bandwidth budgets to aMule, BT and Xunlei.

### Switch the browser UI while retaining port 8084

Set an admin password as `pi` before enabling LAN access:

```bash
read -r -s -p 'New Web admin password: ' AMULE_WEB_PASS
printf '\n'
sudo -u pi /opt/aMule/amuleapi --set-admin-pass="$AMULE_WEB_PASS"
unset AMULE_WEB_PASS
```

Merge into `/home/pi/.aMule/amule.conf` (do not create duplicate sections):

```ini
[AmuleApi]
Enabled=1
HttpPort=8084
BindAddress=0.0.0.0
Path=/opt/aMule/amuleapi

[WebServer]
Enabled=0
```

`amuled` starts the API child and supplies a one-time EC token, so a separate
API systemd service and another copy of the EC password are unnecessary.
Keep the existing `[ExternalConnect]` settings. Keep TCP 4662, UDP 4672,
EC 4712, UPnP and other existing network settings unchanged. Port 8088 belongs
to nginx on this N1; do not replace it.

The supplied units assume `pi`, `/home/pi` and `/home/pi/Downloads`. Review
existing local unit customisations before installing them. The download mount
must be ready before the core starts; the daemon malloc arena cap limits
per-thread allocator overhead without imposing a hard memory limit.

```bash
sudo cp /opt/aMule/systemd/amuled.service /etc/systemd/system/
sudo systemctl disable amuleweb
sudo systemctl daemon-reload
sudo systemctl enable --now amuled
```

Open `http://<N1-IP>:8084/`. Confirm the new interface loads, categories are
present, downloads are intact and the selected share directories are correct.
The legacy Web UI remains bundled for rollback but must not run on the same
HTTP port at the same time. Reverting to it requires disabling `[AmuleApi]`
before starting the legacy service.

### Sharing boundaries

Preserve the existing recursive whitelist: Animations, Audio Books, Books,
Documentaries, Entertainments, Movies, Music, MVs, Software and TV Programs.
Keep `FollowSymlinksInShares=0` and `ShareHiddenFiles=0`. Do not add the whole
Downloads directory as a recursive root. Temp, 云盘缓存文件, `.bt` and
`lost+found` must stay outside the selected roots. Incoming files and verified
parts of active downloads retain aMule's normal sharing behaviour.

Keep filesystem watching on and the existing 30-minute reload script as a
fallback. Do not increase inotify limits unless the watcher actually hits them.

## Upstream references

- [3.1.0 release notes](https://github.com/amule-org/amule/releases/tag/3.1.0)
- [Build switches](https://github.com/amule-org/amule/blob/3.1.0/cmake/options.cmake)
- [New Web/API setup](https://github.com/amule-org/amule/blob/3.1.0/docs/QUICKSTART-AMULEAPI.md)
- [Default preferences](https://github.com/amule-org/amule/blob/3.1.0/src/Preferences.cpp)
