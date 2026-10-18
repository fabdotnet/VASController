# VASController

```
__     __    _     ____    ____                _                 _  _
\ \   / /   / \   / ___|  / ___|  ___   _ __  | |_  _ __   ___  | || |  ___  _ __
 \ \ / /   / _ \  \___ \ | |     / _ \ | '_ \ | __|| '__| / _ \ | || | / _ \| '__|
  \ V /   / ___ \  ___) || |___ | (_) || | | || |_ | |   | (_) || || ||  __/| |
   \_/   /_/   \_\|____/  \____| \___/ |_| |_| \__||_|    \___/ |_||_| \___||_|
```

**Lifecycle manager for Greenbone Community Edition (OpenVAS) in Docker, on Debian and Ubuntu.**
One script, `vasctl`, to install, run, monitor, freeze, back up, move offline and cleanly remove
your Greenbone stack.

---

## Why VASController?

Greenbone provides official containers and a setup script for installing the Community Edition.
VASController covers the rest of the stack's lifecycle: operation, feed monitoring and freezing,
mission backups and restores, offline deployment, and removal.

It wraps these operations in simple commands with safety nets: typed confirmations
for destructive actions, checksummed archives, backups readable by root only, and GSA bound to
`127.0.0.1`. The feed stays **frozen by default**: nothing updates behind your back during an
engagement, and you decide when to refresh it.

## Requirements

- Debian 12+ or Ubuntu 22.04+ (Ubuntu 24.04 LTS is the release officially supported by Greenbone), amd64
- 4 vCPU, 8 GB RAM, 40–60 GB of free disk
- root (sudo)
- Bridged networking recommended: NAT degrades ARP/ICMP host discovery, and `vasctl doctor` warns about it

## Quick start

```bash
sudo bash vasctl.sh install          # Docker (official repo) + official Greenbone compose + images
sudo bash vasctl.sh self-install     # installs the command as /usr/local/sbin/vasctl
sudo vasctl start
sudo vasctl feed-status --watch      # wait until the feed import is complete before scanning
sudo vasctl passwd                   # change the default admin password
```

GSA listens on `https://127.0.0.1` (self-signed certificate). From your workstation:

```bash
ssh -L 8443:127.0.0.1:443 user@scanner-vm    # then open https://127.0.0.1:8443
```

## Commands and options

Run `vasctl help <command>` for the full details of any command, or `vasctl help all` for all of them.

### Setup

| Command | Description |
|---|---|
| `install` | Checks the platform, installs Docker Engine and the compose plugin from Docker's official repository, downloads the official Greenbone compose file into `/opt/greenbone` and pulls all images. Does not start anything. |
| `passwd` | Sets a new password for the GSA `admin` account (prompted twice). |
| `self-install [--dir <path>] [--name <name>]` | Installs the script as a system command (default `/usr/local/sbin/vasctl`, `root:root 0755`). Re-running it is safe. The nightly feed timer, if any, is repointed to the installed copy. |

### Operation

| Command | Description |
|---|---|
| `start` | Starts the stack, waits for GSA to answer, and warns if gvmd is still importing the feed. |
| `stop` | Stops and removes the containers. Volumes and images are kept. |
| `restart [--hard]` | Default: restarts only the running services (fast). `--hard`: full down + up, which recreates every container; use it after editing the compose or lock file. |
| `status` | Container states, GSA reachability, feed version and age, lock state, nightly schedule. |
| `versions` | Images in use and the versions reported by gvmd, ospd-openvas and openvas. |
| `disk` | Disk used by Greenbone images and volumes, grand total, free space in Docker's data directory. |
| `logs [service…]` | Follows the last 100 log lines (e.g. `logs gvmd ospd-openvas`). |
| `services` | Lists the compose services. |
| `doctor` | Read-only preflight checks reported as OK / INFO / WARN / FAIL: distribution, CPU, RAM, NTP, **hypervisor NAT detection** (VirtualBox, libvirt, VMware, Hyper-V, UTM), Docker, ports 443/9392, container health, feed age. Exits with code 1 on any FAIL. |

### Feed and updates

| Command | Description |
|---|---|
| `update-feed [--wait]` | Pulls the latest feed data (NVTs, Notus, SCAP, CERT-Bund, DFN-CERT…); gvmd then re-imports it in the background. `--wait` follows the import with the dashboard. |
| `feed-status [--watch] [--timeout <min>]` | Import progress dashboard: scanner VT loading, gvmd activity, NVT progress bar with rate and ETA, CVE/CPE/CERT counters, highlighted changes and stalled-counter detection. `--watch` refreshes until the import is complete; `--timeout` gives up after N minutes (exit code 1). |
| `schedule-feed enable\|disable\|status\|run` | Optional nightly feed update through a systemd timer (default 01:00, change it with `GB_FEED_SCHEDULE`). Disabled by default. |
| `update [-y]` | Software update of the whole stack: fresh compose file, all images pulled, containers recreated. A major version may migrate the database, so take a snapshot or a `backup` first. |
| `lock` / `unlock` | `lock` pins every service to the digest of the image currently on disk, which freezes both the software and the feed. While locked, `update`, `update-feed` and `schedule-feed enable` are refused. `unlock` releases the pin. |

### Missions and offline use

| Command | Description |
|---|---|
| `backup [--label <name>] [--output <dir>]` | Full archive of the gvmd database plus gvmd's encryption key, so stored credentials stay usable. Fast to restore. Default output: `/var/backups/vasctl`, archives created with mode 0600. |
| `restore <archive> [options]` | Replaces the database with a full backup. |
| `backup-scan --label <name> [--output <dir>]` | **End-of-mission archive, smallest possible**: keeps everything that is yours (targets, credentials, configs, tasks, reports, notes, overrides) and leaves out the SCAP/CERT data, which the feed can rebuild. Uses the strongest compression available (zstd or gzip -9). |
| `restore-scan <archive> [options]` | Restores a mission archive; gvmd then rebuilds SCAP/CERT from the installed feed. **Works on a fresh Debian/Ubuntu**: if nothing is installed, it installs Greenbone first, starts it, then restores. |
| `export-bundle [--output <dir>] [--with-docker]` | Packs all images (software and feed), the compose file and the script into one checksummed archive for an offline host. `--with-docker` also bundles the Docker packages and their dependencies, for a target with no Docker at all (same distribution and release required). |
| `import-bundle <bundle> [-y]` | Offline installation from a bundle: verifies the checksums, installs Docker from the bundle if needed, loads the images and verifies them by ID. |

Options shared by `restore` and `restore-scan`:

| Option | Effect |
|---|---|
| `--bundle <file>` | Fresh offline host: install from this bundle first. |
| `--same-versions` | Fresh online host: reinstall the exact image digests recorded in the archive (gvmd **and** feed of the mission). Requires an archive made while the stack was locked. |
| `--watch` | (`restore-scan` only) Follows the SCAP/CERT rebuild with the dashboard. |
| `--force` | Allows an archive made by a *newer* gvmd. Archives from an older gvmd are accepted automatically, since gvmd migrates them. |
| `-y` | No confirmation prompts. |

### Removal

| Command | Description |
|---|---|
| `uninstall` | Removes containers, networks, images, volumes, `/opt/greenbone` and the nightly timer (typed confirmation). |
| `uninstall --keep-images` | Wipes the database but keeps the images: the next `start` gives a clean stack **without downloading anything**. |
| `uninstall --keep-data` | Keeps the volumes (database and feed) and the compose file. |
| `uninstall --purge-docker` | Also removes Docker itself (packages, `/var/lib/docker`, repository, group), asking again if non-Greenbone containers or images exist. |
| `-y` | No confirmation prompt. |

Other: `help [command\|all\|env]`, `version`. Environment variables (`GB_DIR`, `GB_FEED_SCHEDULE`,
`VAS_THEME`, `NO_COLOR`…) are listed by `vasctl help env`.

## Practical case: end of mission, and a question months later

**March: engagement for ACME.** Before the first scan, refresh the feed, then freeze everything for
the whole engagement:

```bash
sudo vasctl update-feed --wait
sudo vasctl lock
sudo vasctl status          # note the feed version: it belongs in the report
```

**End of the engagement.** Archive the mission **while the stack is still locked**, so the archive
also records the exact image digests. Then start the next mission from a clean database, without
re-downloading gigabytes of images:

```bash
sudo vasctl backup-scan --label acme-2026-03
#   → /var/backups/vasctl/vasctl-scan-acme-2026-03-<date>.tar
sudo vasctl unlock
sudo vasctl uninstall --keep-images -y
sudo vasctl start
```

The archive contains scan credentials and their decryption key: move it to encrypted storage
(or `gpg -c` it).

**September: ACME asks a question** ("Was this host already flagged in March?", "Can you send the
report again?", "Which account did you use for the authenticated scan?"). Your scanner VM has been
rebuilt since then. On any fresh Debian or Ubuntu:

```bash
# Same gvmd and same feed as during the mission (the archive was made while locked)
sudo bash vasctl.sh restore-scan vasctl-scan-acme-2026-03-<date>.tar --same-versions --watch

# Or with the current versions: the CVE details of old reports are rebuilt from today's feed
sudo bash vasctl.sh restore-scan vasctl-scan-acme-2026-03-<date>.tar --watch
```

VASController installs Docker and Greenbone, starts the stack, restores the mission and rebuilds the
SCAP/CERT data. Open GSA through the SSH tunnel: the targets, tasks and reports from March are
there, and the `admin` password is the one you used back then.

> Old image digests can disappear from the registry over time. For long-term, guaranteed
> reproducibility, also keep an offline bundle of the mission:
> `sudo vasctl export-bundle --output /path/to/archive`. Later, restore with
> `restore-scan <archive> --bundle <bundle>`, which needs no Internet access at all.

## Security notes

- The script runs as root and drives Docker and systemd: read it before running it.
- `install` and `update` download the official compose file from `greenbone.github.io`.
- Backups contain secrets (scan credentials and gvmd's encryption key): they are created with
  mode 0600, and you should keep them encrypted.
- GSA is only exposed on `127.0.0.1`. Use an SSH tunnel to reach it.

## Disclaimer

VASController is not affiliated with or endorsed by Greenbone AG. Greenbone and OpenVAS are
trademarks of Greenbone AG.

Only scan systems you are explicitly authorized to test.

## License

[MIT](LICENSE) © 2026 FabDotNET
