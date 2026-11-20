# Patched PHP 7.4 and 5.6 for Ubuntu 20.04 (focal)

Unofficial rebuilds of Ondřej Surý's patched `php7.4` and `php5.6` source
packages for **Ubuntu 20.04 (focal), amd64**, which Sury's repositories no
longer build for. A GitHub Actions workflow checks Sury's pool daily, builds
any new revision that contains the required security fixes, and publishes it
as a GitHub Release. A small script installs the newest release on a server.

> **Unofficial.** These packages are not built or endorsed by the PHP project,
> Ondřej Surý or Canonical. PHP 7.4 and 5.6 are end-of-life; moving to a
> supported PHP version (or upgrading the OS) remains the real fix.

## Contents

| File | Runs on | Purpose |
|---|---|---|
| `build-php-focal.sh` | Build machine / CI | Builds Sury's newest patched source for focal in an `ubuntu:20.04` Docker container. |
| `install-php-debs.sh` | Server | Installs built `.deb` files: only upgrades installed packages, backs up first, dry-runs, asks before installing. |
| `install-from-release.sh` | Server | Downloads the newest release bundle, verifies it and runs `install-php-debs.sh`. |
| `scripts/latest-sury-dsc.sh` | CI | Finds the newest Sury source revision (so CI only builds when something changed). |
| `.github/workflows/build.yml` | GitHub Actions | Builds and publishes releases. |

## Setup

1. Create a GitHub repository and push these files.
2. In **Settings → Actions → General → Workflow permissions**, allow
   **Read and write permissions** (needed to create releases).
3. Edit `REPO=` at the top of `install-from-release.sh` to `your-user/your-repo`,
   commit and push.
4. Go to **Actions → Build patched PHP for Ubuntu 20.04 → Run workflow** for the
   first build. After that it runs daily on its own.

### What the workflow does

- For each PHP version, finds Sury's newest source revision.
- If a release `php<version>-r<revision>` already exists, it stops (unless
  **force** is ticked).
- Otherwise it builds. The build script refuses to build a source whose
  changelog doesn't mention the required CVEs (default: `CVE-2026-109618` and
  `CVE-2026-129496`). In that case the run ends with a notice, not a failure,
  and tries again the next day.
- On success it creates a release with one bundle
  (`php7.4-focal-r<rev>.tar.gz`, containing the `.deb` files, `SHA256SUMS` and
  `install-php-debs.sh`), its `.sha256` file and the full `build.log`.

Manual runs can choose a single version, force a rebuild, or override the
required CVE list.

## Installing on a server

```bash
curl -fsSLO https://raw.githubusercontent.com/<your-user>/<your-repo>/main/install-from-release.sh
chmod +x install-from-release.sh
sudo ./install-from-release.sh 7.4
sudo ./install-from-release.sh 5.6
```

Useful options:

```bash
sudo TAG=php7.4-r32 ./install-from-release.sh 7.4     # a specific release
sudo DOWNLOAD_ONLY=1 ./install-from-release.sh 7.4    # download + verify only
sudo GITHUB_TOKEN=... ./install-from-release.sh 7.4   # private repository
```

The installer:

1. verifies checksums;
2. upgrades **only** the PHP packages already installed (separate extensions
   such as `php7.4-mcrypt` are left as they are);
3. refuses if any new version isn't newer than the installed one;
4. backs up the current packages to `/root/php<ver>-backup-<date>/`;
5. dry-runs and aborts if anything would be removed;
6. asks before installing, keeps your edited config files, restarts
   `php<ver>-fpm` and tests the config.

Rollback (the exact command is printed at the end of each install):

```bash
sudo apt-get install --allow-downgrades /root/php7.4-backup-<date>/*.deb
sudo systemctl restart php7.4-fpm
```

## Building locally instead of in CI

```bash
./build-php-focal.sh 7.4          # or 5.6
# network trouble inside Docker:
MIRROR=http://ubuntu.ethz.ch/ubuntu DOCKER_ARGS="--network host" ./build-php-focal.sh 7.4
```

Then copy `php7.4-focal-debs/` and `install-php-debs.sh` to the server and run
`sudo ./install-php-debs.sh 7.4 /path/to/php7.4-focal-debs`.

## Notes

- **Checksums detect corruption, not tampering.** They come from the same
  release. Anyone who can push to this repository or its releases can change
  what servers install, so protect the repository (2FA, branch protection,
  limited collaborators).
- **Switching away from GetPageSpeed builds:** after a few days without
  problems, remove their repository and the apt pin file so apt never pulls
  those packages back in (the installer prints the commands).
- **Scheduled workflows** in public repositories are disabled by GitHub after
  60 days without repository activity. Re-enable from the Actions tab, or push
  a commit occasionally.
- **Build dependencies** are the likeliest failure: Sury's sources target newer
  releases than focal. Failed runs upload `build.log` as an artifact.
