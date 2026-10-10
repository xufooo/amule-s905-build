#!/usr/bin/env bash
#
# aMule headless bundle — cloud build for Ubuntu 18.04 (bionic) arm64
#
# Runs INSIDE an arm64v8/ubuntu:18.04 container on a native arm64 GitHub
# runner (ubuntu-24.04-arm). The result links against glibc 2.27, matching
# the target box (Armbian 5.77 user-built Ubuntu 18.04.6, Amlogic S905).
#
# Usage: build.sh [AMULE_VERSION] [WX_VERSION] [BOOST_VERSION] [CRYPTOPP_VERSION]
#
# Version pins (all verified against upstream):
#   aMule      3.1.0   tag on amule-org/amule
#   wxWidgets  3.2 branch @ d73e1df63  (2026-08-28)
#                       aMule hard-requires >= 3.2.0 (cmake/wx.cmake)
#                       + wxUSE_WEBREQUEST (--with-libcurl).
#                       Deliberately NOT a 3.2.x release tarball: amuled
#                       needs the wxEpollDispatcher use-after-free fix
#                       (amule-org/amule#1136; wx commit 3382306c8c35,
#                       "Don't call handlers unregistered during
#                       wxEpollDispatcher::Dispatch()") that no 3.2.x
#                       release carries yet. This is the same 3.2-branch
#                       commit the aMule Flathub manifest pins.
#   Boost      1.74.0  aMule hard-requires >= 1.70 (CMakeLists.txt);
#                       gcc 7 (bionic) friendly; headers-only usage
#   Crypto++   8.9.0   aMule hard-requires >= 8.1 (cmake/cryptopp.cmake)
set -euo pipefail

AMULE_VERSION="${1:-3.1.0}"
# wxWidgets 3.2-branch commit pinned by aMule's own Flathub manifest
# (packaging/flathub/org.amule.aMule.yaml). Carries the epoll fix amuled
# needs (#1136) that no 3.2.x release has. Update when 3.2.12 ships.
WX_COMMIT="${2:-d73e1df63abee30759a6c8f134be8c091b619b7e}"
BOOST_VERSION="${3:-1.74.0}"
CRYPTOPP_VERSION="${4:-8.9.0}"

export DEBIAN_FRONTEND=noninteractive
JOBS="${JOBS:-$(nproc)}"
CPU_FLAGS="-mcpu=cortex-a53 -ffunction-sections -fdata-sections"
APPS=(amuled amuleapi amuleweb amulecmd)
SRC=/work/src
STAGE=/work/stage
DIST=/work/dist

log() { printf '\n\033[1;32m[BUILD]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Ubuntu 18.04 is EOL: repoint apt at the old-releases archive.
#    (arm64 packages live under old-releases.PORTS.ubuntu.com)
# ---------------------------------------------------------------------------
log "==> Ubuntu 18.04 EOL: repointing apt at old-releases.ports.ubuntu.com"
sed -i -E \
  -e 's#https?://(archive|security)\.ubuntu\.com/ubuntu#http://old-releases.ports.ubuntu.com/ubuntu#g' \
  -e 's#https?://ports\.ubuntu\.com/ubuntu-ports#http://old-releases.ports.ubuntu.com/ubuntu-ports#g' \
  -e 's#https?://ports\.ubuntu\.com/ubuntu#http://old-releases.ports.ubuntu.com/ubuntu#g' \
  /etc/apt/sources.list
cat /etc/apt/sources.list
apt-get update -yq

log "==> Installing build dependencies"
apt-get install -yq --no-install-recommends \
  build-essential file curl unzip ca-certificates gnupg apt-transport-https pkg-config \
  autoconf automake libtool gettext git python3 \
  libcurl4-openssl-dev libpng-dev \
  libreadline-dev zlib1g-dev libglib2.0-dev libexpat1-dev \
  libupnp-dev libmaxminddb-dev

# ---------------------------------------------------------------------------
# 2. CMake. bionic's own 3.10.2 cannot configure aMule: options.cmake calls
#    add_compile_definitions() unconditionally, a CMake >= 3.12 command
#    (verified against the cmake 3.10.2 source — the version-range syntax in
#    cmake_minimum_required(VERSION 3.10...3.31) parses fine, the commands
#    do not). Rather than a bleeding-edge tarball, take the version Kitware
#    (CMake's vendor) builds FOR Ubuntu 18.04: their apt repo serves
#    cmake 3.25.2 for bionic — the "recommended for 18.04" pick.
#    (Fallback if apt.kitware.com ever drops bionic: cmake.org aarch64
#    tarball, earliest available is 3.21.x.)
# ---------------------------------------------------------------------------
log "==> Installing CMake from Kitware's bionic repo (3.25.2)"
curl -fsSL "https://apt.kitware.com/keys/kitware-archive-latest.asc" \
  | gpg --dearmor -o /usr/share/keyrings/kitware-archive.gpg
echo "deb [signed-by=/usr/share/keyrings/kitware-archive.gpg] https://apt.kitware.com/ubuntu/ bionic main" \
  > /etc/apt/sources.list.d/kitware.list
apt-get update -yq
apt-get install -yq cmake
cmake --version | head -1

mkdir -p "${SRC}" "${STAGE}" "${DIST}"
cd "${SRC}"

# ---------------------------------------------------------------------------
# 3. Crypto++ — static lib + headers. Installed under /usr (NOT /usr/local):
#    distro gcc's default header search path does not include
#    /usr/local/include, and every aMule cmake probe would miss it.
#    Layout mirrors the distro convention: include/cryptopp/*.h
#    -mcpu=cortex-a53: target CPU is the S905's Cortex-A53 (baseline armv8,
#    so no optional +crypto CPU extension is forced). Command-line
#    CXXFLAGS overrides makefile defaults, so supply optimisation explicitly.
# ---------------------------------------------------------------------------
log "==> Building Crypto++ ${CRYPTOPP_VERSION}"
rm -rf cryptopp && mkdir cryptopp && cd cryptopp
curl -fsSL "https://github.com/weidai11/cryptopp/releases/download/CRYPTOPP_${CRYPTOPP_VERSION//./_}/cryptopp${CRYPTOPP_VERSION//./}.zip" -o c.zip
unzip -q c.zip
# The release zip extracts source files at the top level; if it ever
# gains an enclosing directory, descend into it so the copy below works.
if [ ! -f cryptlib.h ]; then
  SUB="$(dirname "$(find . -name cryptlib.h | head -1)")"
  [ "${SUB}" != "." ] && cd "${SUB}"
fi
make -s -j"${JOBS}" CXXFLAGS="-O3 -DNDEBUG -fPIC ${CPU_FLAGS}" libcryptopp.a
mkdir -p /usr/include/cryptopp /usr/lib
cp ./*.h /usr/include/cryptopp/
cp libcryptopp.a /usr/lib/
cd "${SRC}"

# ---------------------------------------------------------------------------
# 4. Boost — aMule uses only header-only asio/error_code (nothing links a
#    prebuilt boost), but boost.cmake does find_package(Boost CONFIG
#    REQUIRED), so the CMake config files must be installed too. Installed
#    under /usr for the same reason as cryptopp (distro gcc searches
#    /usr/include, not /usr/local/include). Note: `b2 --with-system
#    install` DOES generate BoostConfig.cmake but only installs libs/system's
#    OWN headers — boost/asio.hpp lives in its own lib. So after the
#    minimal install, make sure the full header tree is present
#    (b2 headers), with a full install as last resort.
# ---------------------------------------------------------------------------
log "==> Building Boost ${BOOST_VERSION} (headers + cmake config)"
BOOST_U="boost_${BOOST_VERSION//./_}"
rm -rf "${BOOST_U}" && mkdir "${BOOST_U}" && cd "${BOOST_U}"
curl -fsSL "https://archives.boost.io/release/${BOOST_VERSION}/source/${BOOST_U}.tar.gz" -o b.tar.gz
tar xzf b.tar.gz && cd "${BOOST_U}"
./bootstrap.sh --prefix=/usr >/dev/null
./b2 -q -j"${JOBS}" --prefix=/usr --with-system install >/dev/null
if [ ! -f /usr/include/boost/asio.hpp ]; then
  log "==> --with-system install left the header tree incomplete — installing all headers"
  ./b2 -q --prefix=/usr headers >/dev/null
fi
if [ ! -f /usr/include/boost/asio.hpp ] || \
   [ ! -f /usr/include/boost/system/error_code.hpp ]; then
  log "==> boost headers still missing — full b2 install"
  ./b2 -q -j"${JOBS}" --prefix=/usr install >/dev/null
fi
[ -f /usr/include/boost/asio.hpp ] || { echo "FATAL: boost/asio.hpp not installed"; exit 1; }
cd "${SRC}"

# ---------------------------------------------------------------------------
# 5. wxWidgets — 3.2 BRANCH commit (NOT a release tarball), wxBase + libcurl.
#    * Epoll fix: wx commit 3382306c8c35 ("Don't call handlers unregistered
#      during wxEpollDispatcher::Dispatch()") fixes the amuled use-after-free
#      (amule-org/amule#1136) that every 3.2.x release still carries. Pinned
#      to d73e1df63, the same 3.2-branch commit aMule's Flathub manifest
#      ships. Revert to archive tarball when 3.2.12 is out.
#    * All shipped components are headless: build shared wxBase without
#      GTK/X11/OpenGL. Keep libcurl for wxWebRequest (GeoIP/filter updates).
#    * --disable-debug is the big optimization for the weak S905: wx's
#      default configure produces a -g -O0 DEBUG build. --disable-debug
#      flips it to an optimised release build.
# ---------------------------------------------------------------------------
log "==> Building wxWidgets 3.2-branch @ ${WX_COMMIT:0:12} (wxBase, libcurl, optimised)"
# GitHub archive tarballs do NOT include git submodules, and the 3.2
# branch keeps its bundled regex engine (pcre2) as one — so fetch the
# pinned commit with git and init the submodules shallow.
rm -rf "wxWidgets-${WX_COMMIT}"
git init -q "wxWidgets-${WX_COMMIT}" && cd "wxWidgets-${WX_COMMIT}"
git remote add origin "https://github.com/wxWidgets/wxWidgets.git"
git fetch -q --depth 1 origin "${WX_COMMIT}"
git checkout -q FETCH_HEAD
git submodule update -q --init --depth 1
mkdir -p build-base && cd build-base
# -mcpu=cortex-a53 for the target S905 CPU. Passed through configure's
# env so wx APPENDS its own flags (-O2, -fvisibility, defines) on top —
# passing CXXFLAGS to `make` would override the makefile's flags instead.
CFLAGS="${CPU_FLAGS}" CXXFLAGS="${CPU_FLAGS}" ../configure --quiet \
  --prefix=/usr/local \
  --disable-gui --enable-unicode --disable-debug --enable-shared \
  --with-libcurl
make -s -j"${JOBS}"
make install
cd "${SRC}"

# ---------------------------------------------------------------------------
# 6. aMule — daemon + REST/new Web UI + legacy web + cmdline client;
#    no GUI, no remotegui, no ed2k helper — minimal components for the box).
#    CMAKE_INSTALL_PREFIX=/opt/aMule is the FINAL path on the box, so the
#    baked-in template/manpage paths resolve. Staged via DESTDIR.
#    IP2COUNTRY=ON: libmaxminddb reads the DB-IP/MaxMind .mmdb database.
#    MMAP=ON compiles the optional I/O path; runtime stays OFF until measured.
#    BFD=OFF avoids another runtime library; backtraces retain addr2line fallback.
#    UPnP=ON: Ubuntu 18.04's libupnp enables automatic port forwarding.
#    NLS=ON: gettext installed above; ships the .mo catalogs so the box
#    can run with non-English messages if LANG asks for it.
# ---------------------------------------------------------------------------
log "==> Building aMule ${AMULE_VERSION} (${APPS[*]})"
rm -rf "amule-${AMULE_VERSION}"
curl -fsSL "https://github.com/amule-org/amule/archive/refs/tags/${AMULE_VERSION}.tar.gz" -o amule.tar.gz
tar xzf amule.tar.gz
cd "amule-${AMULE_VERSION}"

# bionic's GCC 7 predates the deprecated-copy warning. Remove only those
# two unsupported warning flags from the upstream CMake source for this build.
# bionic glibc 2.27 also needs pthread linked explicitly for the asio probe
# and final binaries.
sed -i '/deprecated-copy/d' src/CMakeLists.txt
sed -i 's#^[[:space:]]*check_include_files ("boost/system/error_code.hpp;boost/asio.hpp" ASIO_SOCKETS LANGUAGE CXX)#set (CMAKE_REQUIRED_LIBRARIES pthread)\ncheck_include_files ("boost/system/error_code.hpp;boost/asio.hpp" ASIO_SOCKETS LANGUAGE CXX)#' cmake/boost.cmake
grep -n "CMAKE_REQUIRED_LIBRARIES pthread" cmake/boost.cmake

configure_amule() {
  cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGITDATE="${AMULE_VERSION}" \
    -DCMAKE_INSTALL_PREFIX=/opt/aMule \
    -DCMAKE_C_FLAGS="${CPU_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${CPU_FLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="-pthread -Wl,--gc-sections" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION="$1" \
    -DBUILD_MONOLITHIC=OFF \
    -DBUILD_REMOTEGUI=OFF \
    -DBUILD_DAEMON=ON \
    -DBUILD_AMULEAPI=ON \
    -DBUILD_WEBSERVER=ON \
    -DBUILD_AMULECMD=ON \
    -DBUILD_ED2K=OFF \
    -DBUILD_TESTING=OFF \
    -DENABLE_IP2COUNTRY=ON \
    -DENABLE_MMAP=ON \
    -DENABLE_BFD=OFF \
    -DENABLE_UPNP=ON \
    -DENABLE_NLS=ON \
    -DENABLE_VERSION_CHECK=ON \
    -DENABLE_ALL_EXPERIMENTAL=OFF \
    -DENABLE_IPV6=OFF \
    -DENABLE_UTP=OFF \
    -DENABLE_KAD_PROTOCOL_10=OFF \
    -DENABLE_KAD_NODE_PROTECTION=OFF
}

if ! configure_amule ON; then
  echo "=== configure failed — dumping CMakeError.log ==="
  tail -80 build/CMakeFiles/CMakeError.log 2>/dev/null || true
  exit 1
fi
# LTO (gcc 7) on this codebase is a gamble — if the link blows up, fall
# back to a plain -mcpu build automatically instead of failing the run.
if ! cmake --build build -j"${JOBS}"; then
  log "==> LTO build failed — falling back to a non-LTO build"
  rm -rf build
  if ! configure_amule OFF; then
    echo "=== fallback configure failed — dumping CMakeError.log ==="
    tail -80 build/CMakeFiles/CMakeError.log 2>/dev/null || true
    exit 1
  fi
  cmake --build build -j"${JOBS}"
fi
DESTDIR="${STAGE}" cmake --install build
cd "${SRC}"

# ---------------------------------------------------------------------------
# 7. Bundle: binaries + share + bundled wx shared libs + launch wrappers.
#    Box layout (extract the tarball as root):
#      /opt/aMule/bin/{amuled,amuleapi,amuleweb,amulecmd}
#      /opt/aMule/lib/*.so        (wx libs)
#      /opt/aMule/share/amule/    (templates etc.)
#      /opt/aMule/{amuled,amuleapi,amuleweb,amulecmd} (LD_LIBRARY_PATH wrappers)
# ---------------------------------------------------------------------------
log "==> Packaging bundle"
AP="${STAGE}/opt/aMule"
mkdir -p "${AP}/lib"
# wx shared libs: copy ONLY the ones the binaries actually resolve
# (amuled/amuleweb/amulecmd link wxBase + wxBase_net — the daemon+web combo
# is GUI-free, so the wxGTK core/adv/stc libs would be dead weight on the
# box). Compute the closure via ldd so it survives wx upgrades.
for app in "${APPS[@]}"; do
  if [ -x "${AP}/bin/${app}" ]; then
    LD_LIBRARY_PATH=/usr/local/lib ldd "${AP}/bin/${app}" 2>/dev/null \
      | awk '/libwx/ {print $1}'
  fi
done | sort -u | while read -r soname; do
  cp -a "/usr/local/lib/${soname}"* "${AP}/lib/"
done
# UPnP shared libraries are provided by the Ubuntu 18.04 runtime package
# on the target; do not copy libupnp into the application bundle.
# Optimisation: strip debug symbols from binaries and bundled libs.
# (Release/-O3 code stays; only symbol tables go — smaller image, faster
# cold start on the box's eMMC, no runtime cost.)
strip --strip-unneeded "${AP}/bin/"* 2>/dev/null || true
strip --strip-unneeded "${AP}/lib/"*.so* 2>/dev/null || true
for app in "${APPS[@]}"; do
  if [ -x "${AP}/bin/${app}" ]; then
    cat > "${AP}/${app}" <<EOF
#!/bin/sh
# aMule ${app} — Ubuntu 18.04 arm64 cloud build
DIR="\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)"
export LD_LIBRARY_PATH="\${DIR}/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\${DIR}/bin/${app}" "\$@"
EOF
    chmod +x "${AP}/${app}"
  fi
done
# Ship the systemd units inside the bundle so deployment is one copy step.
mkdir -p "${AP}/systemd"
cp /work/systemd/*.service "${AP}/systemd/" 2>/dev/null || true
mkdir -p "${AP}/config"
cp /work/config/s905-recommended.ini "${AP}/config/"
cp /work/README.md "${AP}/README.md"

# ---------------------------------------------------------------------------
# 8. Verification: correct arch + no missing shared libs.
# ---------------------------------------------------------------------------
log "==> Verifying artifacts"
for app in "${APPS[@]}"; do
  test -x "${AP}/bin/${app}"
  test -x "${AP}/${app}"
  file "${AP}/bin/${app}" | tee /tmp/amule-file.txt
  grep -q 'ARM aarch64' /tmp/amule-file.txt
  LD_LIBRARY_PATH="${AP}/lib" ldd "${AP}/bin/${app}" > /tmp/amule-ldd.txt
  cat /tmp/amule-ldd.txt
  if grep -q 'not found' /tmp/amule-ldd.txt; then
    echo "MISSING LIBS for ${app}"; exit 1
  fi
  if grep -Ei 'lib(gtk|gdk|wx_gtk|GL[.]|X11)' /tmp/amule-ldd.txt; then
    echo "Unexpected GUI dependency for ${app}"; exit 1
  fi
  # wxApp-based tools print a valid version but return -1 (shell 255)
  # when their OnInit exits early for --version. This is not a build failure.
  version_rc=0
  timeout 15 "${AP}/${app}" --version > /tmp/amule-version.txt 2>&1 || version_rc=$?
  cat /tmp/amule-version.txt
  case "$version_rc" in
    0|255) ;;
    *) echo "Version probe failed for ${app}: ${version_rc}"; exit 1 ;;
  esac
  grep -qi 'amule' /tmp/amule-version.txt
done
test -s "${AP}/share/amule/amuleapi-static/index.html"
test -d "${AP}/share/amule/amuleapi-static/js"
grep -q '^BUILD_AMULEAPI:BOOL=ON$' "${SRC}/amule-${AMULE_VERSION}/build/CMakeCache.txt"
grep -q '^ENABLE_IP2COUNTRY:BOOL=ON$' "${SRC}/amule-${AMULE_VERSION}/build/CMakeCache.txt"
LD_LIBRARY_PATH="${AP}/lib" ldd "${AP}/bin/amuled" | grep 'libmaxminddb'
for app in amuled amuleweb; do
  if ! LD_LIBRARY_PATH="${AP}/lib" ldd "${AP}/bin/${app}" | awk -v systemlib="/usr/lib/aarch64-linux-gnu/" '/lib(upnp|ixml|threadutil)[.]so/ { found++; if (index($3, systemlib) != 1) { print "UPnP runtime library is not from Ubuntu: " $0; bad=1 } } END { if (!found || bad) exit 1 }'; then
    echo "UPnP runtime dependency is not supplied by the Ubuntu system package for ${app}"
    exit 1
  fi
done
echo "--- bundled wx libs ---"
ls "${AP}/lib" | grep -c "\.so" || true

log "==> Smoke testing daemon + new Web/API"
bash /work/scripts/smoke-test.sh "${AP}"

# Keep the feature switches and source identities alongside the archive.
{
  printf 'aMule=%s\nwxWidgets=%s\nBoost=%s\nCrypto++=%s\n' \
    "$AMULE_VERSION" "$WX_COMMIT" "$BOOST_VERSION" "$CRYPTOPP_VERSION"
  grep -E '^(BUILD_|ENABLE_|CMAKE_(BUILD_TYPE|C_FLAGS:|CXX_FLAGS:|INTERPROCEDURAL_OPTIMIZATION))' \
    "${SRC}/amule-${AMULE_VERSION}/build/CMakeCache.txt"
} > "${DIST}/build-features.txt"

# ---------------------------------------------------------------------------
# 9. Tarball + checksum
# ---------------------------------------------------------------------------
log "==> Creating tarball"
cd "${STAGE}"
tar czf "${DIST}/aMule-${AMULE_VERSION}-ubuntu18.04-arm64.tar.gz" opt
cd "${DIST}"
sha256sum "aMule-${AMULE_VERSION}-ubuntu18.04-arm64.tar.gz" > "aMule-${AMULE_VERSION}-ubuntu18.04-arm64.tar.gz.sha256"
ls -la "${DIST}"
log "DONE: $(ls -la "${DIST}"/aMule-*.tar.gz | awk '{print $9, $5" bytes"}')"
