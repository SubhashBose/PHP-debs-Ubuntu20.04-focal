#!/usr/bin/env bash
#
# install-php-debs.sh
#
# Installs packages built by build-php-focal.sh on the server, upgrading ONLY
# the PHP packages that are already installed. Backs up the current packages
# first, verifies checksums, does a dry run, and asks before changing anything.
#
# Usage:
#   sudo ./install-php-debs.sh 7.4 ~/php7.4-focal-debs
#   sudo ./install-php-debs.sh 5.6 ~/php5.6-focal-debs

set -euo pipefail

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

PHP_VER="${1:-}"
DEB_DIR="${2:-}"
case "$PHP_VER" in 7.4|5.6) ;; *) die "Usage: sudo $0 <7.4|5.6> <deb-directory>" ;; esac
[[ -d "$DEB_DIR" ]] || die "Directory not found: $DEB_DIR"
[[ $EUID -eq 0 ]] || die "Run with sudo."
DEB_DIR="$(cd "$DEB_DIR" && pwd)"

# ---------------------------------------------------- verify checksums
if [[ -f "$DEB_DIR/SHA256SUMS" ]]; then
  log "Verifying checksums"
  (cd "$DEB_DIR" && sha256sum -c --ignore-missing --quiet SHA256SUMS) \
    || die "Checksum mismatch. Re-copy the files from the build machine."
else
  warn "No SHA256SUMS file found; skipping checksum verification."
fi

# ------------------------------------------- match installed packages
log "Finding installed PHP $PHP_VER packages"
installed="$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' \
              "php${PHP_VER}*" "libapache2-mod-php${PHP_VER}" 2>/dev/null \
            | awk '$1 == "ii" {print $2}' || true)"
[[ -n "$installed" ]] || die "No installed php${PHP_VER} packages found."

files=()
kept=()
for p in $installed; do
  f="$(ls -1 "$DEB_DIR/${p}_"*.deb 2>/dev/null | head -n1 || true)"
  if [[ -z "$f" ]]; then
    kept+=("$p")
    continue
  fi
  newv="$(dpkg-deb -f "$f" Version)"
  oldv="$(dpkg-query -W -f='${Version}' "$p")"
  if ! dpkg --compare-versions "$newv" gt "$oldv"; then
    die "$p: built version $newv is not newer than installed $oldv. Aborting."
  fi
  printf '  %-28s %s  ->  %s\n' "$p" "$oldv" "$newv"
  files+=("$f")
done

[[ ${#files[@]} -gt 0 ]] || die "None of the installed packages have a new build in $DEB_DIR."
if [[ ${#kept[@]} -gt 0 ]]; then
  echo
  echo "No new build for these (separate extensions, left unchanged):"
  printf '  %s\n' "${kept[@]}"
fi

# ------------------------------------------------------------- backup
BACKUP_DIR="/root/php${PHP_VER}-backup-$(date +%Y%m%d-%H%M%S)"
log "Backing up current packages to $BACKUP_DIR"
command -v dpkg-repack >/dev/null 2>&1 || apt-get install -y -qq dpkg-repack >/dev/null
mkdir -p "$BACKUP_DIR"
(cd "$BACKUP_DIR" && for p in $installed; do dpkg-repack "$p" >/dev/null; done)
ls -1 "$BACKUP_DIR" | sed 's/^/  /'

# ------------------------------------------------------------ dry run
log "Dry run"
sim="$(apt-get -s install "${files[@]}" 2>&1)" || { echo "$sim"; die "Dry run failed."; }
if grep -q '^Remv' <<<"$sim"; then
  grep '^Remv' <<<"$sim"
  die "The install would REMOVE packages. Aborting; nothing was changed."
fi
grep -E '^Inst' <<<"$sim" | sed 's/^/  /'

echo
read -rp "Proceed with the installation? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || die "Cancelled. Nothing was changed."

# ------------------------------------------------------------ install
log "Installing (keeping your existing config files)"
UCF_FORCE_CONFFOLD=1 DEBIAN_FRONTEND=noninteractive \
  apt-get install -y -o Dpkg::Options::=--force-confold "${files[@]}"

# ---------------------------------------------------- restart, verify
log "Testing configuration and restarting php${PHP_VER}-fpm"
php-fpm${PHP_VER} -t
systemctl restart "php${PHP_VER}-fpm"
systemctl is-active --quiet apache2 && systemctl reload apache2 || true
systemctl --no-pager --lines=0 status "php${PHP_VER}-fpm" || true

log "Installed versions"
dpkg-query -W -f='  ${Package} ${Version}\n' $installed

if php-fpm${PHP_VER} -i 2>/dev/null | grep -qi everpatch; then
  warn "An 'everpatch' section is still present; some GetPageSpeed package may remain."
else
  echo "  No GetPageSpeed 'everpatch' component present."
fi

cat <<EOF

Done. Test your PHP $PHP_VER sites now.

Rollback if something is wrong:
  sudo apt-get install --allow-downgrades $BACKUP_DIR/*.deb
  sudo systemctl restart php${PHP_VER}-fpm

EOF

if [[ "$PHP_VER" == "7.4" ]]; then
cat <<'EOF'
Once PHP 7.4 has run fine for a few days, remove the GetPageSpeed repository
so apt never pulls its packages back in:
  dpkg -l | grep -i getpagespeed          # find the release package name
  sudo apt remove <that-package>
  sudo rm -f /etc/apt/preferences.d/getpagespeed-php
  sudo apt update

EOF
fi
