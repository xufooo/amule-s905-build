# aMule 3.1.0 for S905 / Ubuntu 18.04 ARM64

Build a headless aMule bundle for Cortex-A53 and glibc 2.27 using a native
ARM64 GitHub Actions runner and an Ubuntu 18.04 build container.

## Components

- `amuled`: eD2k / Kad daemon.
- `amuleapi`: REST API and new Web UI.
- `amuleweb`: legacy Web UI.
- `amulecmd`: command-line client.

## Build options

- Cortex-A53 compiler target; release optimisation, LTO with a non-LTO fallback,
  and linker garbage collection.
- Shared wxBase with networking and libcurl; no GTK, X11 or OpenGL dependency.
- GeoIP via `libmaxminddb`, UPnP and translations enabled.
- Optional memory-mapped I/O support compiled in.
- BFD, experimental IPv6, uTP and Kad extensions disabled.
- wxWidgets pinned to `d73e1df63abee30759a6c8f134be8c091b619b7e`,
  Boost 1.74.0 and Crypto++ 8.9.0.

## Build

Open **Actions → aMule build — Ubuntu 18.04 arm64 → Run workflow**.
The build logic and dependency versions are in the workflow file.
`publish_release` defaults to false; enable it to publish a release.

The workflow checks executable architecture, shared-library dependencies,
version output, Web UI assets and GeoIP support before uploading artifacts.

Outputs:

- `aMule-<version>-ubuntu18.04-arm64.tar.gz`: programs, wxBase libraries and
  application resources under `/opt/aMule`.
- The corresponding `.sha256` checksum.
- `build-features.txt`: build switches and source versions.

## Upstream

- [aMule](https://github.com/amule-org/amule)
- [3.1.0 release notes](https://github.com/amule-org/amule/releases/tag/3.1.0)
