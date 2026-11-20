#!/usr/bin/env bash
#
# install-from-release.sh
#
# Downloads the newest patched PHP build for Ubuntu 20.04 from this
# repository's GitHub Releases, verifies it, and runs install-php-debs.sh
# (which backs up, dry-runs and asks before installing anything).
#
# Usage on the server:
#   sudo ./install-from-release.sh 7.4
#   sudo ./install-from-release.sh 5.6
#
# Optional environment variables:
#   REPO=owner/name     GitHub repository (default set below)
#   TAG=php7.4-r32      Install this release instead of the newest one
#   GITHUB_TOKEN=...    Needed for private repositories
#   DOWNLOAD_ONLY=1     Download and verify, but don't run the installer
#   WORK_ROOT=/path     Where to keep downloads (default /root/php-builds)

set -euo pipefail

# >>> Set this to your repository <<<
REPO="${REPO:-SubhashBose/PHP-debs-Ubuntu20.04-focal}"

PHP_VER="${1:-}"
TAG="${TAG:-}"
WORK_ROOT="${WORK_ROOT:-/root/php-builds}"
DOWNLOAD_ONLY="${DOWNLOAD_ONLY:-0}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- checks
case "$PHP_VER" in 7.4|5.6) ;; *) die "Usage: sudo $0 <7.4|5.6>" ;; esac
[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ "$REPO" != your-github-user/* ]] || \
  die "Set your repository first: edit REPO at the top of this script, or run with REPO=owner/name."

. /etc/os-release
[[ "${VERSION_CODENAME:-}" == "focal" ]] || \
  die "These packages are built for Ubuntu 20.04 (focal) only. This system is: ${PRETTY_NAME:-unknown}"
[[ "$(dpkg --print-architecture)" == "amd64" ]] || die "These packages are built for amd64 only."

for cmd in curl python3 tar sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

API="https://api.github.com/repos/$REPO"
auth=()
[[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
gh_api() { curl -fsSL "${auth[@]}" -H "Accept: application/vnd.github+json" "$1"; }

# ------------------------------------------------------- pick a release
if [[ -z "$TAG" ]]; then
  log "Looking up the newest PHP $PHP_VER release in $REPO"
  TAG="$(gh_api "$API/releases?per_page=100" | python3 -c '
import json, re, sys
ver = sys.argv[1]
best = None
for r in json.load(sys.stdin):
    if r.get("draft") or r.get("prerelease"):
        continue
    m = re.fullmatch(r"php" + re.escape(ver) + r"-r(\d+)", r.get("tag_name", ""))
    if m and (best is None or int(m.group(1)) > best[0]):
        best = (int(m.group(1)), r["tag_name"])
print(best[1] if best else "")
' "$PHP_VER")" || die "Could not query GitHub releases for $REPO."
  [[ -n "$TAG" ]] || die "No PHP $PHP_VER release found in $REPO yet."
fi
echo "Release: $TAG"

# ------------------------------------------------------ find the assets
assets="$(gh_api "$API/releases/tags/$TAG" | python3 -c '
import json, sys
for a in json.load(sys.stdin).get("assets", []):
    n = a["name"]
    if n.endswith(".tar.gz") or n.endswith(".tar.gz.sha256"):
        print("\t".join([n, a["browser_download_url"], a["url"]]))
')" || die "Could not read release $TAG."

bundle_line="$(grep -P '\.tar\.gz\t' <<<"$assets" | head -n1 || true)"
sum_line="$(grep -P '\.tar\.gz\.sha256\t' <<<"$assets" | head -n1 || true)"
[[ -n "$bundle_line" && -n "$sum_line" ]] || die "Release $TAG is missing its bundle or checksum file."

WORK="$WORK_ROOT/$TAG"
mkdir -p "$WORK"
cd "$WORK"

download() {  # download <name> <browser_url> <api_url>
  local name="$1" burl="$2" aurl="$3"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL "${auth[@]}" -H "Accept: application/octet-stream" -o "$name" "$aurl"
  else
    curl -fsSL -o "$name" "$burl"
  fi
}

log "Downloading to $WORK"
IFS=$'\t' read -r bname burl aurl <<<"$bundle_line"
IFS=$'\t' read -r sname surl saurl <<<"$sum_line"
download "$sname" "$surl" "$saurl"
download "$bname" "$burl" "$aurl"

log "Verifying the bundle"
sha256sum -c "$sname" || die "Checksum mismatch for $bname. Delete $WORK and try again."

log "Extracting"
rm -rf "$WORK/debs"
mkdir -p "$WORK/debs"
tar -xzf "$bname" -C "$WORK/debs"
[[ -f "$WORK/debs/install-php-debs.sh" ]] || die "install-php-debs.sh is missing from the bundle."
chmod +x "$WORK/debs/install-php-debs.sh"
ls -1 "$WORK/debs"/*.deb | wc -l | xargs echo "Packages in bundle:"

if [[ "$DOWNLOAD_ONLY" == "1" ]]; then
  echo
  echo "Downloaded and verified. To install later:"
  echo "  sudo $WORK/debs/install-php-debs.sh $PHP_VER $WORK/debs"
  exit 0
fi

# ------------------------------------------------------- run installer
log "Starting the installer"
# The installer asks for confirmation; make sure it can read from the terminal
# even when this script itself was piped into bash.
if [[ -t 0 ]]; then
  "$WORK/debs/install-php-debs.sh" "$PHP_VER" "$WORK/debs"
elif [[ -r /dev/tty ]]; then
  "$WORK/debs/install-php-debs.sh" "$PHP_VER" "$WORK/debs" < /dev/tty
else
  die "No terminal available for the confirmation prompt. Run:
  sudo $WORK/debs/install-php-debs.sh $PHP_VER $WORK/debs"
fi
