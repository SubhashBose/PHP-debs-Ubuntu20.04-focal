#!/usr/bin/env bash
#
# build-php-focal.sh
#
# Builds Ondřej Surý's latest patched PHP 7.4 or PHP 5.6 source packages for
# Ubuntu 20.04 (focal) inside an ubuntu:20.04 Docker container.
# Replaces the earlier build-php56-focal.sh.
#
# Run on a separate build machine with Docker (amd64), NOT on the server.
#
# Usage:
#   chmod +x build-php-focal.sh
#   ./build-php-focal.sh 7.4
#   ./build-php-focal.sh 5.6
#
# Output: ./php<version>-focal-debs/  (.deb files, SHA256SUMS, build.log)
#
# Optional environment variables:
#   REQUIRE_CVES="..."  CVE IDs the source changelog must mention.
#                       Default: "CVE-2026-109618 CVE-2026-129496"
#                       (PHP2Shell + the November 2026 release).
#   DSC_URL=...         Use this exact .dsc URL instead of auto-detecting.
#   MIN_REV=N           Ignore Sury revisions below N (default 0).
#   OUT_DIR=...         Output directory.
#   JOBS=N              Parallel build jobs (default: number of CPUs).
#   MIRROR=URL          Ubuntu mirror to use inside the container instead of
#                       archive.ubuntu.com, e.g. http://ubuntu.ethz.ch/ubuntu
#   DOCKER_ARGS="..."   Extra docker run options, e.g. "--network host"
#                       or "--dns 1.1.1.1".
#
# Unofficial rebuild. You are responsible for maintaining these packages.

set -euo pipefail

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

PHP_VER="${1:-}"
case "$PHP_VER" in
  7.4|5.6) ;;
  *) die "Usage: $0 <7.4|5.6>" ;;
esac

POOL_URL="https://packages.sury.org/php/pool/main/p/php${PHP_VER}/"
REQUIRE_CVES="${REQUIRE_CVES:-CVE-2026-109618 CVE-2026-129496}"
MIN_REV="${MIN_REV:-0}"
OUT_DIR="${OUT_DIR:-$PWD/php${PHP_VER}-focal-debs}"
DSC_URL="${DSC_URL:-}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
IMAGE="ubuntu:20.04"
MIRROR="${MIRROR:-}"
DOCKER_ARGS="${DOCKER_ARGS:-}"

# ---------------------------------------------------------------- checks
command -v docker >/dev/null 2>&1 || die "Docker is not installed or not in PATH."
docker info >/dev/null 2>&1 || die "Cannot talk to Docker (daemon down, or try sudo)."
command -v curl >/dev/null 2>&1 || die "curl is required on the build machine."

ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" || "$ARCH" == "amd64" ]] || \
  warn "This machine is $ARCH; the build runs under amd64 emulation and may take hours."

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# ------------------------------------------------- find the newest .dsc
if [[ -z "$DSC_URL" ]]; then
  log "Looking for the newest php${PHP_VER} source in Sury's pool"
  listing="$(curl -fsSL "$POOL_URL")" || die "Could not fetch $POOL_URL"

  ver_re="${PHP_VER//./\\.}"
  dscs="$(printf '%s' "$listing" \
          | sed 's/%2[Bb]/+/g; s/%7[Ee]/~/g' \
          | grep -oE "php${ver_re}_[0-9.]+-[0-9]+[^\"<> ]*\.dsc" \
          | sort -u || true)"
  [[ -n "$dscs" ]] || die "No php${PHP_VER} .dsc files found. Set DSC_URL manually."

  # Highest revision wins; prefer an Ubuntu 22.04 build of that revision.
  best="$(printf '%s\n' "$dscs" | awk -v min="$MIN_REV" '
    {
      if (!match($0, /_[0-9.]+-[0-9]+/)) next
      s = substr($0, RSTART, RLENGTH); sub(/^.*-/, "", s); rev = s + 0
      if (rev < min) next
      pref = ($0 ~ /ubuntu22\.04/) ? 3 : (($0 ~ /ubuntu/) ? 2 : (($0 ~ /deb11|debian11/) ? 1 : 0))
      score = rev * 10 + pref
      if (score > best) { best = score; name = $0 }
    }
    END { print name }')"
  [[ -n "$best" ]] || die "No suitable php${PHP_VER} source found."
  DSC_URL="${POOL_URL}${best}"
fi

log "PHP version:  $PHP_VER"
log "Source:       $DSC_URL"
log "Required CVE: $REQUIRE_CVES"
log "Output:       $OUT_DIR"
log "Building in $IMAGE (PHP 7.4 builds ~40 packages: allow 30-90 minutes)"

# ---------------------------------------------------- build in container
# shellcheck disable=SC2086
docker run --rm -i \
  --platform linux/amd64 \
  $DOCKER_ARGS \
  -e MIRROR="$MIRROR" \
  -e DSC_URL="$DSC_URL" \
  -e REQUIRE_CVES="$REQUIRE_CVES" \
  -e JOBS="$JOBS" \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -v "$OUT_DIR":/out \
  "$IMAGE" bash -s <<'INNER' 2>&1 | tee "$OUT_DIR/build.log"
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export DEBEMAIL="builder@localhost"
export DEBFULLNAME="Local focal rebuild"
step() { printf '\n--- %s\n' "$*"; }

step "Configuring apt sources"
if [ -n "${MIRROR:-}" ]; then
  M="${MIRROR%/}"
  sed -i "s#http://archive.ubuntu.com/ubuntu#${M}#g; s#http://security.ubuntu.com/ubuntu#${M}#g" \
    /etc/apt/sources.list
  echo "Using mirror: $M"
fi
# The ubuntu:20.04 image usually lists focal-backports already; add it only if missing.
if ! grep -qE '^deb .* focal-backports ' /etc/apt/sources.list; then
  echo "deb ${MIRROR:-http://archive.ubuntu.com/ubuntu} focal-backports main universe" \
    > /etc/apt/sources.list.d/focal-backports.list
fi

step "Updating package lists"
apt-get update 2>&1 | tee /tmp/apt-update.log
if grep -qE '^(W: Failed to fetch|E: )' /tmp/apt-update.log; then
  echo "" >&2
  echo "ERROR: the container could not download Ubuntu package lists (network problem)." >&2
  echo "Re-run with a different mirror and/or Docker network settings, for example:" >&2
  echo "  MIRROR=http://ubuntu.ethz.ch/ubuntu ./build-php-focal.sh <version>" >&2
  echo "  DOCKER_ARGS=\"--network host\" ./build-php-focal.sh <version>" >&2
  exit 4
fi

step "Installing build tools"
apt-get install -y -qq --no-install-recommends \
  build-essential devscripts equivs dpkg-dev fakeroot wget ca-certificates lsb-release >/dev/null
apt-get install -y -qq --no-install-recommends -t focal-backports debhelper >/dev/null
echo "debhelper: $(dpkg-query -W -f='${Version}' debhelper)"

mkdir -p /build && cd /build

step "Downloading source package"
dget -u -d "$DSC_URL"
DSC_FILE="$(ls -1 php*.dsc | head -n1)"

step "Extracting $DSC_FILE"
dpkg-source -x "$DSC_FILE" src

step "Top of the source changelog"
head -n 30 src/debian/changelog

step "Checking required security fixes"
missing=""
for cve in $REQUIRE_CVES; do
  grep -q "$cve" src/debian/changelog || missing="$missing $cve"
done
if [ -n "$missing" ]; then
  echo "ERROR: the changelog does not mention:$missing" >&2
  echo "Sury may not have published a fixed build yet. If the changelog above" >&2
  echo "clearly shows the fixes under other wording, re-run with REQUIRE_CVES set." >&2
  exit 3
fi
echo "All required CVEs found."

step "Installing build dependencies"
if ! mk-build-deps -i -r \
      -t "apt-get -y --no-install-recommends -o Debug::pkgProblemResolver=yes" \
      src/debian/control; then
  echo "ERROR: build dependencies could not be satisfied on Ubuntu 20.04." >&2
  echo "The messages above name the package/version focal is missing." >&2
  exit 2
fi

step "Marking the version as a focal rebuild"
cd src
dch --local "+focal" --distribution focal --force-distribution \
  "Rebuild of Sury's patched source for Ubuntu 20.04 (focal)."
echo "Package version: $(dpkg-parsechangelog -S Version)"

step "Building (tests skipped, $JOBS jobs)"
DEB_BUILD_OPTIONS="nocheck parallel=$JOBS" dpkg-buildpackage -us -uc -b

step "Collecting packages"
cd /build
find . -maxdepth 1 -name '*.deb' ! -name '*build-deps*' -exec cp {} /out/ \;
cd /out
sha256sum ./*.deb > SHA256SUMS
chown -R "$HOST_UID:$HOST_GID" /out
ls -1 /out/*.deb
INNER

shopt -s nullglob
debs=("$OUT_DIR"/*.deb)
[[ ${#debs[@]} -gt 0 ]] || die "No .deb files produced. See $OUT_DIR/build.log"

log "Done: ${#debs[@]} packages in $OUT_DIR"
cat <<EOF

Next: copy the whole folder (including SHA256SUMS) and install-php-debs.sh
to the server, then run:

  sudo ./install-php-debs.sh $PHP_VER /path/to/php${PHP_VER}-focal-debs

EOF
