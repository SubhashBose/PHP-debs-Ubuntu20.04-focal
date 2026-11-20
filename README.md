# Patched PHP 7.4 and 5.6 for Ubuntu 20.04 (focal)

Unofficial rebuilds of Ondřej Surý's patched `php7.4` and `php5.6` source
packages for **Ubuntu 20.04 (focal), amd64**, which Sury's repositories no
longer build for. A GitHub Actions workflow checks Sury's pool daily, builds
any new revision that contains the required security fixes, and publishes it
as a GitHub Release. A small script installs the newest release on a server.

> **Unofficial.** These packages are not built or endorsed by the PHP project,
> Ondřej Surý or Canonical. PHP 7.4 and 5.6 are end-of-life; moving to a
> supported PHP version (or upgrading the OS) remains the real fix.


### What this repository does

- Daily check for Sury's newest source revision for each of PHP versions (7.5 and 5.6).
- If a release `php<version>-r<revision>` already exists, it stops.
- Otherwise it builds. The build script refuses to build a source whose
  changelog doesn't mention the required CVEs [default: `CVE-2026-109618` (PHP2Shell CVEs) and
  `CVE-2026-129496` (phpAfterShell CVEs)].
- On success it creates a release with one bundle
  (`php7.4-focal-r<rev>.tar.gz`, containing the `.deb` files, `SHA256SUMS` and
  `install-php-debs.sh`), its `.sha256` file and the full `build.log`.

Repo maintainer can choose to run a single version, force a rebuild, or override the
required CVE list.

## Installing on a server

Oneline install
```bash
# For PHP 7.4
curl -sL https://raw.githubusercontent.com/SubhashBose/PHP-debs-Ubuntu20.04-focal/main/install-from-release.sh | bash -s -- 7.4

# For PHP 5.6
curl -sL https://raw.githubusercontent.com/SubhashBose/PHP-debs-Ubuntu20.04-focal/main/install-from-release.sh | bash -s -- 5.6
```

Useful options:

```bash
sudo TAG=php7.4-r32 ./install-from-release.sh 7.4     # a specific release
sudo DOWNLOAD_ONLY=1 ./install-from-release.sh 7.4    # download + verify only
sudo GITHUB_TOKEN=... ./install-from-release.sh 7.4   # private repository
```

## What the installer does:

1. verifies checksums;
2. upgrades **only** the PHP packages already installed (separate extensions
   such as `php7.4-mcrypt` are left as they are);
3. refuses if any new version isn't newer than the installed one;
4. backs up the current packages to `/root/php<ver>-backup-<date>/`;
5. dry-runs and aborts if anything would be removed;
6. asks before installing, keeps your edited config files, restarts
   `php<ver>-fpm` and tests the config.

### Rollback (the exact command is printed at the end of each install):

```bash
sudo apt-get install --allow-downgrades /root/php7.4-backup-<date>/*.deb
sudo systemctl restart php7.4-fpm
```

## (Alternative) Building locally and deploying to server

```bash
./build-php-focal.sh 7.4          # or 5.6
# network trouble inside Docker:
MIRROR=http://ubuntu.ethz.ch/ubuntu DOCKER_ARGS="--network host" ./build-php-focal.sh 7.4
```

Then copy `php7.4-focal-debs/` and `install-php-debs.sh` to the server and run
`sudo ./install-php-debs.sh 7.4 /path/to/php7.4-focal-debs`.

