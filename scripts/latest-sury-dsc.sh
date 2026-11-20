#!/usr/bin/env bash
#
# latest-sury-dsc.sh <7.4|5.6>
#
# Prints "<revision> <dsc-url>" for the newest php<version> source package in
# Ondřej Surý's pool, preferring the Ubuntu 22.04 build of that revision.
# Uses the same selection rules as build-php-focal.sh. Used by the workflow
# to decide whether a new build is needed before starting one.

set -euo pipefail

PHP_VER="${1:-}"
case "$PHP_VER" in 7.4|5.6) ;; *) echo "Usage: $0 <7.4|5.6>" >&2; exit 1 ;; esac

POOL_URL="https://packages.sury.org/php/pool/main/p/php${PHP_VER}/"
ver_re="${PHP_VER//./\\.}"

listing="$(curl -fsSL "$POOL_URL")"

result="$(printf '%s' "$listing" \
  | sed 's/%2[Bb]/+/g; s/%7[Ee]/~/g' \
  | grep -oE "php${ver_re}_[0-9.]+-[0-9]+[^\"<> ]*\.dsc" \
  | sort -u \
  | awk '
    {
      if (!match($0, /_[0-9.]+-[0-9]+/)) next
      s = substr($0, RSTART, RLENGTH); sub(/^.*-/, "", s); rev = s + 0
      pref = ($0 ~ /ubuntu22\.04/) ? 3 : (($0 ~ /ubuntu/) ? 2 : (($0 ~ /deb11|debian11/) ? 1 : 0))
      score = rev * 10 + pref
      if (score > best) { best = score; bestrev = rev; name = $0 }
    }
    END { if (name != "") print bestrev, name }')"

[[ -n "$result" ]] || { echo "No php${PHP_VER} source found in $POOL_URL" >&2; exit 1; }

read -r rev name <<<"$result"
echo "$rev ${POOL_URL}${name}"
