#!/usr/bin/env bash
# VASController (vasctl.sh) — Install and manage Greenbone Community Edition (OpenVAS) containers on Debian / Ubuntu
# by FabDotNET
# Usage: sudo ./vasctl.sh <command> [options]   (run without arguments for help)
set -Eeuo pipefail

APP_NAME="VASController"
APP_VERSION="1.1.1"
APP_AUTHOR="FabDotNET"
APP_BIN="$(basename "$0")"
APP_PATH="$(readlink -f "$0")"

# ---------- Configuration (can be overridden with environment variables) ----------
GB_DIR="${GB_DIR:-/opt/greenbone}"
GB_PROJECT="${GB_PROJECT:-greenbone-community-edition}"
GB_COMPOSE_URL="${GB_COMPOSE_URL:-https://greenbone.github.io/docs/latest/_static/compose.yaml}"
GB_GSA_URL="${GB_GSA_URL:-https://127.0.0.1}"            # nginx + self-signed TLS (official compose)
GB_START_TIMEOUT="${GB_START_TIMEOUT:-600}"      # max seconds to wait for GSA
GB_FEED_SCHEDULE="${GB_FEED_SCHEDULE:-*-*-* 01:00:00}"   # systemd OnCalendar for nightly feed updates
GB_PULL_RETRIES="${GB_PULL_RETRIES:-4}"          # attempts per image pull (VM NAT / laptop sleep make big pulls flaky)
GB_FEED_LOCK="${GB_FEED_LOCK:-/run/vasctl-feed.lock}"   # serializes update-feed runs (timer + manual)
GB_DATA_COPY_TIMEOUT="${GB_DATA_COPY_TIMEOUT:-5400}"     # max seconds for feed containers to copy data into volumes

ASSUME_YES="${ASSUME_YES:-0}"

FEED_SERVICES=(notus-data vulnerability-tests scap-data dfn-cert-data cert-bund-data report-formats data-objects gpg-data)

FEED_UNIT="vasctl-feed-update"
LEGACY_UNITS=(gb-feed-update)   # units from the earlier manual setup, cleaned up on uninstall

# ---------- Helpers ----------
# Colors: mid-tone 256-color palette, readable on both dark and light backgrounds.
# Override with VAS_THEME=dark|light (or set COLORFGBG, exported by some terminals).
c_bold=$'\e[1m'; c_rst=$'\e[0m'
vas_theme="${VAS_THEME:-}"
if [[ -z "$vas_theme" && -n "${COLORFGBG:-}" ]]; then
  # COLORFGBG="fg;bg" — bg 0-6 or 8 = dark, 7 or 9-15 = light
  case "${COLORFGBG##*;}" in 0|1|2|3|4|5|6|8) vas_theme=dark ;; *) vas_theme=light ;; esac
fi
case "$vas_theme" in
  dark)   # bright tones for black backgrounds
    c_info=$'\e[38;5;81m';  c_ok=$'\e[38;5;114m'; c_warn=$'\e[38;5;221m'; c_err=$'\e[38;5;203m' ;;
  light)  # deep tones for white backgrounds
    c_info=$'\e[38;5;25m';  c_ok=$'\e[38;5;28m';  c_warn=$'\e[38;5;130m'; c_err=$'\e[38;5;124m' ;;
  *)      # neutral default: mid tones that work on both
    c_info=$'\e[38;5;33m';  c_ok=$'\e[38;5;34m';  c_warn=$'\e[38;5;172m'; c_err=$'\e[38;5;160m' ;;
esac
c_banner="$c_bold"   # banner: terminal default color, bold only (readable on any background)
# No colors outside a terminal, or when NO_COLOR is set (https://no-color.org)
if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then c_info=''; c_ok=''; c_warn=''; c_err=''; c_bold=''; c_banner=''; c_rst=''; fi
info() { printf '%s[*]%s %s\n' "$c_info" "$c_rst" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_ok" "$c_rst" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_warn" "$c_rst" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_err" "$c_rst" "$*" >&2; exit 1; }
trap 'die "Failed at line $LINENO: $BASH_COMMAND"' ERR
# Temp dirs registered here are removed on any exit (success, die, Ctrl+C)
CLEANUP=()
cleanup_all() { local d; for d in "${CLEANUP[@]}"; do if [[ -n "$d" ]]; then rm -rf -- "$d"; fi; done; }
trap cleanup_all EXIT
IN_RESTORE=0

banner() {
  # Only on an interactive terminal (keeps journald/systemd output clean)
  [[ -t 1 ]] || return 0
  printf '%s' "$c_banner"
  cat <<'EOF'
__     __    _     ____    ____                _                 _  _
\ \   / /   / \   / ___|  / ___|  ___   _ __  | |_  _ __   ___  | || |  ___  _ __
 \ \ / /   / _ \  \___ \ | |     / _ \ | '_ \ | __|| '__| / _ \ | || | / _ \| '__|
  \ V /   / ___ \  ___) || |___ | (_) || | | || |_ | |   | (_) || || ||  __/| |
   \_/   /_/   \_\|____/  \____| \___/ |_| |_| \__||_|    \___/ |_||_| \___||_|
EOF
  printf '%s' "$c_rst"
  printf '%s  Greenbone / OpenVAS container manager for Debian / Ubuntu — by %s%s\n\n' "$c_bold" "$APP_AUTHOR" "$c_rst"
}

require_root() { [[ $EUID -eq 0 ]] || die "Run $APP_NAME with sudo/root."; }

# Compose wrapper: adds the lock override (images pinned by digest) when present
dc() {
  local files=(-f "$GB_DIR/docker-compose.yml")
  if [[ -f "$GB_DIR/docker-compose.lock.yml" ]]; then files+=(-f "$GB_DIR/docker-compose.lock.yml"); fi
  docker compose "${files[@]}" -p "$GB_PROJECT" "$@"
}
# Base compose only (ignores the lock)
dc_base() { docker compose -f "$GB_DIR/docker-compose.yml" -p "$GB_PROJECT" "$@"; }

# Feed data containers still copying into their volume although Docker already flags them
# "unhealthy": on a slow (virtual) disk, copying ~11 GB of SCAP data takes longer than the
# healthcheck window baked into the image (scap-data: 300 s start period + 3 x 30 s), and
# 'compose up' then aborts the whole start even though the copy finishes fine later.
data_copy_pending() {
  local svc id st out=()
  for svc in "${FEED_SERVICES[@]}"; do
    id="$(dc ps -aq "$svc" 2>/dev/null | head -1)" || id=""
    [[ -n "$id" ]] || continue
    st="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id" 2>/dev/null)" || continue
    if [[ "$st" == "running unhealthy" || "$st" == "running starting" ]]; then out+=("$svc"); fi
  done
  printf '%s' "${out[*]}"
}

# 'docker compose up -d' that waits for slow feed data copies instead of failing on them
dc_up_patient() {
  local attempt=1 pending t0 n=0
  while :; do
    if dc up -d "$@"; then return 0; fi
    pending="$(data_copy_pending)"
    [[ -n "$pending" ]] || return 1
    (( attempt >= 3 )) && return 1
    warn "Feed data is still being copied into the volumes by: $pending"
    warn "(slow disk: the copy outlasts the containers' healthcheck window) — waiting, then starting again…"
    t0=$(date +%s)
    while [[ -n "$(data_copy_pending)" ]]; do
      (( $(date +%s) - t0 < GB_DATA_COPY_TIMEOUT )) || { warn "Still copying after ${GB_DATA_COPY_TIMEOUT}s (GB_DATA_COPY_TIMEOUT)."; return 1; }
      n=$(( n + 1 )); (( n % 8 == 0 )) && info "… still copying ($(fmt_duration $(( $(date +%s) - t0 ))))"
      sleep 15
    done
    info "Feed data copied after $(fmt_duration $(( $(date +%s) - t0 ))) more."
    attempt=$(( attempt + 1 ))
  done
}

# One SQL query in the gvmd database, unaligned output (empty on any error)
pg_q() { dc exec -T -u postgres pg-gvm psql -d gvmd -tAqc "$1" 2>/dev/null | tr -d '\r' || true; }

# 'docker compose pull' with retries. Multi-GB pulls through a hypervisor NAT, a VPN or across a
# host sleep fail often; layers already downloaded are kept, so a retry resumes where it stopped.
# Errors a retry cannot fix (disk full) stop at once; a layer corrupted on disk after its
# download is evicted from containerd's content store so the next attempt fetches it again.
dc_pull_retry() {
  local n=1 delay=15 log rc digest
  log="$(mktemp)"; CLEANUP+=("$log")
  while :; do
    if dc pull "$@" 2>&1 | tee "$log"; then rc=0; else rc=1; fi
    (( rc == 0 )) && return 0
    if grep -qiE 'no space left on device' "$log"; then
      warn "Disk full while pulling images: free space first (sudo $APP_BIN disk), retrying is useless."
      return 1
    fi
    if grep -qiE 'invalid tar header|failed to extract layer|unexpected EOF|digest mismatch|checksum' "$log"; then
      warn "A downloaded layer is corrupted on disk. In a VM this points to the virtual disk or host storage"
      warn "(VirtualBox: check the host disk, free space on the host, 'Use Host I/O Cache')."
      while read -r digest; do
        [[ -n "$digest" ]] || continue
        if command -v ctr >/dev/null && ctr -n moby content rm "$digest" >/dev/null 2>&1; then
          info "Evicted corrupted layer $digest from the content store."
        fi
      done < <(grep -oE 'failed to extract layer \([^)]*sha256:[0-9a-f]{64}' "$log" | grep -oE 'sha256:[0-9a-f]{64}' | sort -u || true)
    fi
    if (( n >= GB_PULL_RETRIES )); then
      warn "Image pull failed after $n attempts."
      return 1
    fi
    warn "Image pull failed (attempt $n/$GB_PULL_RETRIES), retrying in ${delay}s…"
    sleep "$delay"; n=$(( n + 1 )); delay=$(( delay * 2 ))
  done
}

is_locked() { [[ -f "$GB_DIR/docker-compose.lock.yml" ]]; }
require_unlocked() {
  if is_locked; then die "Stack is locked (images pinned by digest): '$1' is disabled. Run 'sudo $APP_BIN unlock' first."; fi
}

# Feed version from the scanner's feed (PLUGIN_SET = "YYYYMMDDhhmm"), "unknown" if unavailable
feed_version() {
  local v
  v="$(dc exec -T ospd-openvas sh -c 'grep -m1 "PLUGIN_SET" /var/lib/openvas/plugins/plugin_feed_info.inc 2>/dev/null' 2>/dev/null \
       | grep -oE '[0-9]{8,12}' | head -1)" || v=""
  printf '%s' "${v:-unknown}"
}
feed_age_days() {
  local v=$1 d
  [[ "$v" =~ ^[0-9]{8} ]] || { echo -1; return; }
  d=$(date -d "${v:0:4}-${v:4:2}-${v:6:2}" +%s 2>/dev/null) || { echo -1; return; }
  echo $(( ($(date +%s) - d) / 86400 ))
}
fmt_feed_version() {
  local v=$1
  if [[ "$v" =~ ^[0-9]{12}$ ]]; then printf '%s-%s-%s %s:%s' "${v:0:4}" "${v:4:2}" "${v:6:2}" "${v:8:2}" "${v:10:2}"
  elif [[ "$v" =~ ^[0-9]{8} ]]; then printf '%s-%s-%s' "${v:0:4}" "${v:4:2}" "${v:6:2}"
  else printf '%s' "$v"; fi
}

# Read KEY=value from a manifest without sourcing it (bundles/backups are untrusted input)
manifest_get() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }

# Verify SHA256SUMS inside an extracted bundle/backup directory
verify_sums() {
  local dir=$1
  [[ -f "$dir/SHA256SUMS" ]] || die "SHA256SUMS missing in $(basename "$dir") — not a $APP_NAME archive?"
  ( cd "$dir" && sha256sum --quiet -c SHA256SUMS ) || die "Integrity check failed (corrupted or tampered archive)."
  ok "Integrity check passed."
}
write_sums() {
  local dir=$1
  ( cd "$dir" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum ) >"$dir/SHA256SUMS"
}

# Extract a .tar archive into a fresh temp dir; prints the single top-level directory
extract_archive() {
  local file=$1 tmp top
  # Runs in a $(…) subshell: clean up here on failure, the caller registers the dir on success
  tmp="$(mktemp -d /var/tmp/vasctl.XXXXXX)"; chmod 0755 "$tmp"
  if ! tar -xf "$file" -C "$tmp" --no-same-owner 2>/dev/null; then
    rm -rf -- "$tmp"; die "Not a valid archive (or truncated): $file"
  fi
  top="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [[ -n "$top" ]] || { rm -rf -- "$tmp"; die "Unexpected archive layout: $file"; }
  printf '%s' "$top"
}

require_compose_file() {
  if [[ -d "$GB_DIR" && ! -r "$GB_DIR" ]]; then
    die "Permission denied on $GB_DIR — run with sudo."
  fi
  [[ -f "$GB_DIR/docker-compose.yml" ]] || die "No compose file in $GB_DIR — run first: sudo $APP_BIN install"
}

# Docker must be installed and its daemon running. With "start", try to start the daemon.
require_docker() {
  command -v docker >/dev/null || die "Docker is not installed — run: sudo $APP_BIN install"
  docker info >/dev/null 2>&1 && return 0
  if [[ "${1:-}" == start ]]; then
    info "Starting the Docker daemon…"
    systemctl start docker 2>/dev/null || true
    docker info >/dev/null 2>&1 && return 0
  fi
  die "The Docker daemon is not running — run: sudo systemctl start docker"
}

# GSA is served by nginx with a self-signed certificate: -k is expected here
gsa_up() { curl -fsk -o /dev/null --max-time 5 "$GB_GSA_URL" 2>/dev/null; }

# Detect the distribution: sets DISTRO_ID (debian|ubuntu) and DISTRO_CODENAME
detect_distro() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found."
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  case "$DISTRO_ID" in
    debian) DISTRO_CODENAME="${VERSION_CODENAME:-}" ;;
    ubuntu) DISTRO_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" ;;
    *) die "Unsupported distribution: $DISTRO_ID (supported: Debian, Ubuntu)." ;;
  esac
  [[ -n "$DISTRO_CODENAME" ]] || die "Cannot determine the $DISTRO_ID release codename."
  DISTRO_VERSION="${VERSION_ID:-unknown}"
}

check_platform() {
  detect_distro
  info "Detected: ${PRETTY_NAME:-$DISTRO_ID $DISTRO_VERSION} ($DISTRO_CODENAME)"
  case "$DISTRO_ID" in
    debian) [[ "${DISTRO_VERSION%%.*}" =~ ^[0-9]+$ ]] && (( ${DISTRO_VERSION%%.*} >= 12 )) \
              || warn "Debian $DISTRO_VERSION: Debian 12+ recommended." ;;
    ubuntu) [[ "${DISTRO_VERSION%%.*}" =~ ^[0-9]+$ ]] && (( ${DISTRO_VERSION%%.*} >= 22 )) \
              || warn "Ubuntu $DISTRO_VERSION: Ubuntu 22.04 LTS+ recommended (24.04 LTS is officially supported by Greenbone)." ;;
  esac
  local arch; arch="$(dpkg --print-architecture)"
  [[ "$arch" == "amd64" ]] || warn "Architecture $arch: Greenbone images target amd64, this may fail."
  local mem_gb; mem_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
  (( mem_gb >= 7 )) || warn "Detected RAM: ~${mem_gb} GB (8 GB recommended)."
  local probe="$GB_DIR"; while [[ ! -d "$probe" && "$probe" != / ]]; do probe="$(dirname "$probe")"; done
  local disk_gb; disk_gb="$(df -BG --output=avail "$probe" 2>/dev/null | tail -1 | tr -dc '0-9')" || disk_gb=""
  (( ${disk_gb:-0} >= 30 )) || warn "Free space: ${disk_gb:-?} GB on $probe (plan for 40 GB+ for the feed and PostgreSQL)."
}

# ---------- Phase 1: installation ----------
install_docker() {
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    ok "Docker + compose plugin already installed ($(docker --version))."
    return
  fi
  info "Removing potentially conflicting packages…"
  for p in docker.io docker-doc docker-compose podman-docker containerd runc; do
    if dpkg -s "$p" >/dev/null 2>&1; then apt-get remove -y "$p"; fi
  done

  [[ -n "${DISTRO_ID:-}" ]] || detect_distro
  local repo="https://download.docker.com/linux/$DISTRO_ID"
  info "Adding the official Docker repository ($repo, $DISTRO_CODENAME)…"
  apt-get update
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "$repo/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] $repo $DISTRO_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  ok "Docker installed ($(docker --version))."
}

add_user_to_docker_group() {
  local u="${SUDO_USER:-}"
  [[ -n "$u" && "$u" != "root" ]] || return 0
  if id -nG "$u" | grep -qw docker; then return 0; fi
  usermod -aG docker "$u"
  warn "$u added to the docker group (root-equivalent — log out and back in to apply)."
}

fetch_compose() {
  install -d -m 0750 "$GB_DIR"
  local tmp; tmp="$(mktemp)"
  if [[ -n "${GB_COMPOSE_SRC:-}" ]]; then
    info "Using the compose file from the archive (same versions as the source)"
    cp "$GB_COMPOSE_SRC" "$tmp"
  else
    info "Downloading the official compose file: $GB_COMPOSE_URL"
    if ! curl -fsSL "$GB_COMPOSE_URL" -o "$tmp"; then
      rm -f "$tmp"
      die "Cannot download the compose file (no Internet access?). Offline host: use 'import-bundle'."
    fi
  fi
  if [[ -f "$GB_DIR/docker-compose.yml" ]] && ! cmp -s "$tmp" "$GB_DIR/docker-compose.yml"; then
    cp "$GB_DIR/docker-compose.yml" "$GB_DIR/docker-compose.yml.$(date +%Y%m%d-%H%M%S).bak"
    warn "Existing compose file differs: backed up as .bak before replacing."
  fi
  install -m 0640 "$tmp" "$GB_DIR/docker-compose.yml"
  rm -f "$tmp"
  dc config --quiet || die "Invalid docker-compose.yml."
  ok "Compose file in place in $GB_DIR."
}

cmd_install() {
  require_root
  check_platform
  install_docker
  add_user_to_docker_group
  fetch_compose
  if [[ -n "${GB_LOCK_SRC:-}" ]]; then
    install -m 0640 "$GB_LOCK_SRC" "$GB_DIR/docker-compose.lock.yml"
    info "Lock file from the archive applied: pulling the exact image digests of the source."
  fi
  info "Pulling Greenbone images (several GB, be patient)…"
  if ! dc_pull_retry; then
    if [[ -n "${GB_LOCK_SRC:-}" ]]; then
      rm -f "$GB_DIR/docker-compose.lock.yml"   # do not leave a lock that would block a retry
      die "Some pinned images are no longer available in the registry: retry without --same-versions, or use a bundle."
    fi
    die "Image pull failed."
  fi
  ok "Installation complete."
  (( IN_RESTORE )) && return 0
  echo
  echo "Next steps: sudo $APP_BIN start   then   sudo $APP_BIN passwd"
  echo "Optional:   sudo $APP_BIN self-install   (install as /usr/local/sbin/vasctl)"
  echo "            sudo $APP_BIN schedule-feed enable   (nightly feed update — feed stays frozen otherwise)"
}

# ---------- Phase 2: normal operation ----------
wait_for_gsa() {
  info "Waiting for GSA at $GB_GSA_URL (timeout ${GB_START_TIMEOUT}s)…"
  local t=0
  until gsa_up; do
    if (( t >= GB_START_TIMEOUT )); then
      warn "GSA not responding after ${GB_START_TIMEOUT}s — check: sudo $APP_BIN logs nginx gsad"
      return 1
    fi
    sleep 5; t=$((t + 5))
  done
  ok "GSA is reachable."
}

feed_hint() {
  # gvmd starts its feed jobs a few seconds after GSA answers: give it a moment, then ask its log
  local act="" i
  for i in 1 2 3; do
    act="$(gvmd_activity)" || act=""
    [[ -n "$act" ]] && break
    sleep 5
  done
  if [[ -n "$act" ]]; then
    warn "gvmd is loading the feed ($act): wait before scanning — progress: sudo $APP_BIN feed-status --watch"
  else
    info "Before scanning, check the feed is loaded: sudo $APP_BIN feed-status"
  fi
}

cmd_start() {
  require_root
  require_compose_file
  require_docker start
  info "Starting the stack…"
  dc_up_patient || die "The stack did not start: sudo $APP_BIN status / logs <service>"
  wait_for_gsa || true
  feed_hint
  echo
  echo "GSA access: $GB_GSA_URL (local to the VM, self-signed certificate)"
  echo "From your workstation: ssh -L 8443:127.0.0.1:443 <user>@<vm_ip>  then https://127.0.0.1:8443"
}

cmd_stop() {
  require_root; require_compose_file; require_docker
  info "Stopping the stack (volumes kept)…"
  dc down
  ok "Stack stopped."
}

cmd_restart() {
  require_root; require_compose_file; require_docker start
  case "${1:-}" in
    --hard)
      # down + up: recreates containers (picks up compose file changes)
      warn "Hard restart: recreating all containers."
      cmd_stop
      cmd_start
      ;;
    "")
      # Soft: restart running services only (avoids re-running feed data containers)
      local running; mapfile -t running < <(dc ps --status running --services)
      if (( ${#running[@]} == 0 )); then
        warn "No running services — starting the stack."
        cmd_start
        return
      fi
      info "Soft restart: ${running[*]}"
      dc restart "${running[@]}"
      wait_for_gsa || true
      feed_hint
      ;;
    *) die "Unknown option: $1 (expected: --hard)" ;;
  esac
}

cmd_status() {
  require_root; require_compose_file; require_docker
  dc ps
  echo
  if gsa_up; then ok "GSA reachable ($GB_GSA_URL)"; else warn "GSA unreachable"; fi
  feed_hint
  local fv; fv="$(feed_version)"
  if [[ "$fv" == unknown ]]; then
    if service_running ospd-openvas; then info "Feed version: unknown (feed not loaded yet?)"; else info "Feed version: unknown (scanner not running)"; fi
  else
    info "Feed version: $(fmt_feed_version "$fv") ($(feed_age_days "$fv") days old)"
  fi
  if is_locked; then info "Images: LOCKED (pinned by digest — sudo $APP_BIN unlock)"; else info "Images: following compose tags (sudo $APP_BIN lock to pin)"; fi
  if [[ -f "/etc/systemd/system/$FEED_UNIT.timer" ]]; then
    info "Scheduled feed update: enabled (next run: $(systemctl show -p NextElapseUSecRealtime --value "$FEED_UNIT.timer" 2>/dev/null || echo unknown))"
  else
    info "Scheduled feed update: disabled ($APP_BIN schedule-feed enable)"
  fi
}

cmd_versions() {
  require_root; require_compose_file; require_docker
  info "Images in use (tag = release channel defined by the official compose file):"
  dc images
  echo
  info "Component versions:"
  local v
  if gvmd_running; then
    v="$(dc exec -T gvmd gvmd --version 2>/dev/null | head -1)" || v=""
    printf '  gvmd          %s\n' "${v:-n/a}"
  else
    printf '  gvmd          %s\n' "not running"
  fi
  v="$(dc exec -T ospd-openvas ospd-openvas --version 2>/dev/null | head -1)" || v=""
  printf '  ospd-openvas  %s\n' "${v:-n/a (not running?)}"
  v="$(dc exec -T ospd-openvas openvas --version 2>/dev/null | head -1)" || v=""
  printf '  openvas       %s\n' "${v:-n/a}"
}

# ---------- Feed import progress ----------
# gvmd gives no percentage: progress is derived from what is already in PostgreSQL, from the
# feed versions on disk vs. in the database, and from gvmd's start/end log markers per job.

FEED_POLL="${FEED_POLL:-15}"   # seconds between two polls

# Row counts "nvts|cves|cpes|cert_bund|dfn_cert|cves_build|cpes_build" (-1 = table not there,
# -2 = table locked right now). gvmd builds SCAP data in a temporary "scap2" schema and swaps it
# to "scap" at the end; during parts of that build it holds ACCESS EXCLUSIVE locks on the scap2
# tables for minutes. One statement per table with a short lock_timeout, so a locked table only
# costs its own counter instead of freezing the whole dashboard.
feed_db_counts() {
  local t sql="SET lock_timeout = '1500ms'; SET statement_timeout = '60s';"$'\n' out v res=()
  for t in nvts scap.cves scap.cpes cert.cert_bund_advs cert.dfn_cert_advs scap2.cves scap2.cpes; do
    sql+="SELECT '$t=' || CASE WHEN to_regclass('$t') IS NULL THEN -1 ELSE (xpath('/row/c/text()', query_to_xml('select count(*) as c from $t', false, true, '')))[1]::text::bigint END;"$'\n'
  done
  out="$(dc exec -T -u postgres pg-gvm psql -d gvmd -tAq <<<"$sql" 2>/dev/null | tr -d '\r')" || true
  for t in nvts scap.cves scap.cpes cert.cert_bund_advs cert.dfn_cert_advs scap2.cves scap2.cpes; do
    v="$(grep -m1 "^$t=" <<<"$out" | cut -d= -f2)" || v=""
    [[ "$v" =~ ^-?[0-9]+$ ]] || v=-2
    res+=("$v")
  done
  local IFS='|'; printf '%s' "${res[*]}"
}

# Start time of a service's container (RFC 3339), for 'docker logs --since'; 24h if unknown
svc_started_at() {
  local id t=""
  id="$(dc ps -q "$1" 2>/dev/null | head -1)" || id=""
  [[ -n "$id" ]] && { t="$(docker inspect -f '{{.State.StartedAt}}' "$id" 2>/dev/null)" || t=""; }
  printf '%s' "${t:-24h}"
}

# Feed versions present on disk, i.e. what the data containers copied into the volumes
disk_nvt_version()     { feed_version; }   # PLUGIN_SET, "unknown" if unavailable
disk_secinfo_version() {                   # scap|cert -> YYYYMMDDhhmm from the feed timestamp file
  local v
  v="$(dc exec -T gvmd cat "/var/lib/gvm/$1-data/timestamp" 2>/dev/null | tr -dc '0-9')" || v=""
  printf '%s' "${v:-unknown}"
}
# NVT feed version gvmd has imported into PostgreSQL
db_nvt_version() { local v; v="$(pg_q "select value from meta where name='nvts_feed_version'")"; printf '%s' "${v:-none}"; }

# State of gvmd's feed jobs from its log, since $1 (default: gvmd container start). The last
# start/end marker of each job wins. Prints "scap=<s> cert=<s> nvt=<s>", s = run|done|failed|none.
# (gvmd no longer sets "gvmd: Updating…" process titles in current images, so titles cannot be used.)
gvmd_job_states() {
  local since="${1:-$(svc_started_at gvmd)}"
  { dc logs --no-log-prefix --since "$since" gvmd 2>/dev/null || true; } | awk '
    /update_scap: Updating data from feed|rebuilding SCAP db/ { s = "run" }
    /Updating SCAP info succeeded/                            { s = "done" }
    /(update_scap|SCAP info).*[Ff]ailed/                      { s = "failed" }
    /sync_cert: Updating data from feed/                      { c = "run" }
    /Updating CERT info succeeded/                            { c = "done" }
    /(sync_cert|CERT info).*[Ff]ailed/                        { c = "failed" }
    /different VT status.*Starting update/                    { n = "run" }
    /Updating VTs in database \.\.\. done/                    { n = "done" }
    /(Updating VTs|update_nvts|update_nvt_cache).*[Ff]ail/    { n = "failed" }
    /manage: +INFO:/ && !/get_nvt_preference|update_dfn_xml|update_cert_bund_xml/ {
      step = $0; sub(/^.*utc:[0-9]+: +/, "", step); sub(/^Updating \/var\/lib\/gvm\//, "reading ", step) }
    END { printf "scap=%s cert=%s nvt=%s step=%s\n", s ? s : "none", c ? c : "none", n ? n : "none", step }'
}

# Bytes held by a leftover "scap2" schema from an aborted SCAP build, 0 if none (or if a build
# is running). gvmd builds scap2 in a transaction that keeps locks on its tables, so a scap2
# with no lock held by a client (autovacuum workers do not count) while no SCAP job runs is garbage - typically a build that hit a full disk, which
# leaves ~25 GB behind and the disk at 100% (PostgreSQL can then no longer write anything).
scap2_leftover_bytes() {
  local b
  b="$(pg_q "SELECT CASE WHEN to_regnamespace('scap2') IS NULL THEN 0
      WHEN EXISTS (SELECT 1 FROM pg_locks l JOIN pg_class c ON c.oid = l.relation
                   JOIN pg_namespace n ON n.oid = c.relnamespace
                   JOIN pg_stat_activity a ON a.pid = l.pid
                   WHERE n.nspname = 'scap2' AND a.backend_type = 'client backend') THEN 0
      ELSE (SELECT coalesce(sum(pg_total_relation_size(c.oid)), 0) FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'scap2' AND c.relkind IN ('r', 'm')) END")"
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  if (( b > 0 )) && [[ "${FW_JOBS:-$(gvmd_job_states)}" == *scap=run* ]]; then b=0; fi
  printf '%s' "$b"
}

# Drop an aborted scap2 build (gvmd starts every SCAP build from scratch anyway). Prints freed bytes.
drop_scap2_leftover() {
  local b; b="$(scap2_leftover_bytes)"
  (( b > 0 )) || { printf '0'; return 0; }
  pg_q "DROP SCHEMA IF EXISTS scap2 CASCADE" >/dev/null
  printf '%s' "$b"
}

# Number of times the kernel OOM killer killed gvmd/postgres in the last hour. With too little
# RAM (and no swap) gvmd's NVT import child (~2.5 GB) is killed every couple of minutes and
# gvmd restarts the import forever without logging anything: the import never ends.
oom_kills_recent() {
  journalctl -k --since -1h --no-pager 2>/dev/null | grep -cE 'Killed process [0-9]+ \((gvmd|postgres)\)' || true
}

# Current gvmd feed activity as a short comma-separated text (empty when idle)
gvmd_activity() {
  local st acts=()
  st="${FW_JOBS:-$(gvmd_job_states)}"
  [[ "$st" == *scap=run* ]] && acts+=("updating SCAP (CVE/CPE)")
  [[ "$st" == *cert=run* ]] && acts+=("updating CERT advisories")
  [[ "$st" == *nvt=run* ]]  && acts+=("importing NVTs")
  local out="" a step
  for a in "${acts[@]}"; do out+="${out:+, }$a"; done
  # Last step gvmd announced: long steps (one UPDATE can run 45 min on a slow disk) show progress
  step="${st#*step=}"; [[ "$st" == *step=* ]] || step=""
  [[ -n "$out" && -n "$step" ]] && out+=" — ${step:0:60}"
  # One SQL statement can run for hours on a slow disk with little RAM: show how long, so a
  # quiet dashboard is not mistaken for a hang
  if [[ -n "$out" ]]; then
    local q
    q="$(pg_q "SELECT extract(epoch FROM max(now() - query_start))::bigint FROM pg_stat_activity
               WHERE datname = 'gvmd' AND usename = 'gvmd' AND state = 'active' AND backend_type = 'client backend'")"
    if [[ "$q" =~ ^[0-9]+$ ]] && (( q >= 300 )); then out+=" (current SQL step running for $(fmt_duration "$q"))"; fi
  fi
  printf '%s' "$out"
}

# Last VT-loading message from ospd-openvas (gvmd only gets NVTs once ospd has loaded them into redis)
ospd_vt_phase() {
  local line
  line="$(dc logs --no-log-prefix --since "$(svc_started_at ospd-openvas)" ospd-openvas 2>/dev/null \
    | grep -iE 'loading vts|finished loading vts|vts were up to date|vt cache' | tail -1)" || true
  if [[ -z "$line" ]]; then printf 'unknown'
  elif grep -qiE 'finished|up to date|updated' <<<"$line"; then printf 'VTs loaded'
  else printf 'loading VTs into redis'
  fi
}

fmt_duration() { printf '%02d:%02d:%02d' $(( $1 / 3600 )) $(( $1 % 3600 / 60 )) $(( $1 % 60 )); }

fmt_count() { if (( $1 < 0 )); then printf 'pending'; else printf "%'d" "$1"; fi; }

fmt_rate() {
  # fmt_rate <per-minute rate>  ->  "~140/s" or "~35/min"
  local pm=$1
  if (( pm >= 60 )); then printf '~%s/s' "$(fmt_count $(( pm / 60 )))"; elif (( pm > 0 )); then printf '~%s/min' "$pm"; fi
}

# Unicode icons when the locale is UTF-8, ASCII otherwise (or VAS_ASCII=1)
fw_init_glyphs() {
  if [[ -z "${VAS_ASCII:-}" && "$(locale charmap 2>/dev/null)" == "UTF-8" ]]; then
    G_DONE='✓'; G_RUN='⟳'; G_WAIT='·'; G_STALL='!'; G_UNK='?'
    G_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  else
    G_DONE='OK'; G_RUN='..'; G_WAIT='--'; G_STALL='!!'; G_UNK='??'
    G_SPIN=('|' '/' '-' '\')
  fi
  if [[ -n "$c_rst" ]]; then c_dim=$'\e[2m'; else c_dim=''; fi
}

FW_STALL="${FW_STALL:-600}"   # seconds without change (while not done) before flagging a counter as stalled

# Record a sample for metric $1 with value $2 at time $3; sets FW_CHANGED[$1] and FW_DELTA[$1]
fw_track() {
  local k=$1 v=$2 now=$3 prev="${FW_LAST[$1]:-}" arr
  FW_CHANGED[$k]=0; FW_DELTA[$k]=0
  if [[ -n "$prev" && "$v" != "$prev" ]]; then
    FW_CHANGED[$k]=1; FW_CHG_T[$k]=$now; FW_LASTCHANGE=$now
    (( prev >= 0 && v > prev )) && FW_DELTA[$k]=$(( v - prev ))
  fi
  [[ -n "${FW_CHG_T[$k]:-}" ]] || FW_CHG_T[$k]=$now
  FW_LAST[$k]=$v
  # keep the last 4 samples "t:v" for a smoothed rate
  local h="${FW_HIST[$k]:-} $now:$v"
  read -ra arr <<<"$h"
  (( ${#arr[@]} > 4 )) && arr=("${arr[@]: -4}")
  FW_HIST[$k]="${arr[*]}"
}

# Smoothed rate of metric $1, per minute (0 if unknown)
fw_rate_pm() {
  local arr first last t0 v0 t1 v1
  read -ra arr <<<"${FW_HIST[$1]:-}"
  (( ${#arr[@]} >= 2 )) || { echo 0; return; }
  # oldest sample with a real value (tables may not exist in early samples)
  local x; first=""
  for x in "${arr[@]}"; do if (( ${x#*:} >= 0 )); then first=$x; break; fi; done
  last="${arr[-1]}"
  [[ -n "$first" && "$first" != "$last" ]] || { echo 0; return; }
  t0=${first%%:*}; v0=${first#*:}; t1=${last%%:*}; v1=${last#*:}
  if (( t1 > t0 && v0 >= 0 && v1 > v0 )); then echo $(( (v1 - v0) * 60 / (t1 - t0) )); else echo 0; fi
}

# State of metric: waiting | run | done | stall
fw_state() {
  local k=$1 v=$2 done_cond=$3 now=$4
  if (( v < 0 )); then echo waiting
  elif (( FW_CHANGED[$k] )); then echo run
  elif (( done_cond )); then echo "done"
  elif (( now - FW_CHG_T[$k] >= FW_STALL )); then echo stall
  else echo run
  fi
}

fw_icon() {
  case "$1" in
    done)    printf '%s%-2s%s' "$c_ok" "$G_DONE" "$c_rst" ;;
    run)     printf '%s%-2s%s' "$c_info" "$G_RUN" "$c_rst" ;;
    stall)   printf '%s%-2s%s' "$c_warn" "$G_STALL" "$c_rst" ;;
    waiting) printf '%s%-2s%s' "$c_dim" "$G_WAIT" "$c_rst" ;;
    *)       printf '%-2s' "$G_UNK" ;;
  esac
}

# Value text, highlighted green if it changed since the previous refresh (padded before coloring)
fw_value() {
  local k=$1 text=$2 width=$3 state=$4 padded
  printf -v padded "%-${width}s" "$text"
  if (( FW_CHANGED[$k] )); then printf '%s%s%s' "$c_ok$c_bold" "$padded" "$c_rst"
  elif [[ "$state" == stall ]]; then printf '%s%s%s' "$c_warn" "$padded" "$c_rst"
  elif [[ "$state" == waiting ]]; then printf '%s%s%s' "$c_dim" "$padded" "$c_rst"
  else printf '%s' "$padded"
  fi
}

# Delta + rate suffix for a metric
fw_extra() {
  local k=$1 state=${2:-run} out="" r
  (( FW_DELTA[$k] > 0 )) && out+="$c_ok+$(fmt_count "${FW_DELTA[$k]}")$c_rst  "
  if [[ "$state" != "done" ]]; then r="$(fw_rate_pm "$k")"; (( r > 0 )) && out+="($(fmt_rate "$r"))"; fi
  printf '%s' "$out"
}

# Prints the dashboard once. Returns 0 when the import is complete, 1 while in progress,
# 2 when gvmd logged a failed feed job.
# Optional globals set by 'update-feed --wait': FW_SINCE (time of the update) and
# FW_NEED_SCAP / FW_NEED_CERT (1 = new data on disk: a finished job after FW_SINCE is required).
feed_progress_once() {
  local counts nvt cve cpe cbund dfn cve2 cpe2 activity vtphase now elapsed v
  FW_LOCKED=0
  counts="$(feed_db_counts)" || counts=""
  IFS='|' read -r nvt cve cpe cbund dfn cve2 cpe2 <<<"${counts:-||||||}"
  for v in nvt cve cpe cbund dfn cve2 cpe2; do
    [[ "${!v}" =~ ^-?[0-9]+$ ]] || printf -v "$v" '%s' -1
    # -2: table locked by gvmd right now -> keep the previous value (or -1 if none yet)
    if (( ${!v} == -2 )); then printf -v "$v" '%s' "${FW_PREVCOUNT[$v]:--1}"; FW_LOCKED=1; fi
    FW_PREVCOUNT[$v]=${!v}
  done
  FW_JOBS="$(gvmd_job_states)" || FW_JOBS=""
  activity="$(gvmd_activity)" || activity=""
  vtphase="$(ospd_vt_phase)" || vtphase=unknown
  local dv dbv; dv="$(disk_nvt_version)" || dv=unknown; dbv="$(db_nvt_version)" || dbv=none
  now=$(date +%s); elapsed=$(( now - FW_START ))

  # SCAP is built in "scap2" then swapped: while scap2 exists, show its counters (on an update
  # the old "scap" stays in place, and in use, until the swap)
  local cve_v=$cve cpe_v=$cpe cve_b=0 cpe_b=0
  (( cve2 >= 0 )) && { cve_v=$cve2; cve_b=1; }
  (( cpe2 >= 0 )) && { cpe_v=$cpe2; cpe_b=1; }

  fw_track nvt "$nvt" "$now"; fw_track cve "$cve_v" "$now"; fw_track cpe "$cpe_v" "$now"
  fw_track cbund "$cbund" "$now"; fw_track dfn "$dfn" "$now"

  # NVTs are complete when gvmd's imported feed version matches the feed on disk. (Counting
  # .nasl files is wrong: the database also holds ~100k Notus local-security checks.)
  local nvt_done=0 nvt_note=""
  if [[ "$dv" =~ ^[0-9]+$ ]]; then
    [[ "$dbv" == "$dv" ]] && (( nvt > 0 )) && nvt_done=1
  else
    (( nvt > 0 )) && [[ "$FW_JOBS" != *nvt=run* ]] && nvt_done=1
  fi
  local s_nvt s_cve s_cpe s_cb s_dfn
  s_nvt=$(fw_state nvt "$nvt" "$nvt_done" "$now")
  if (( nvt_done )); then
    s_nvt="done"; nvt_note="feed $(fmt_feed_version "$dv")"
  elif [[ "$FW_JOBS" == *nvt=run* ]]; then
    s_nvt=run; nvt_note="importing feed $(fmt_feed_version "$dv")"
  elif [[ "$vtphase" == "loading VTs into redis" ]]; then
    s_nvt=run; nvt_note="scanner is loading VTs first"
  elif [[ "$FW_JOBS" == *scap=run* || "$FW_JOBS" == *cert=run* ]]; then
    # gvmd imports NVTs only after the SecInfo (SCAP/CERT) sync: waiting here is normal
    s_nvt=waiting; nvt_note="queued: gvmd imports NVTs after SCAP/CERT"
  else
    [[ "$s_nvt" == "done" ]] && s_nvt="run"
    nvt_note="feed $(fmt_feed_version "$dv"), database $(fmt_feed_version "$dbv")"
  fi
  [[ "$s_nvt" == stall ]] && nvt_note+=" (stalled?)"
  s_cve=$(fw_state cve "$cve_v" "$(( !cve_b && cve > 0 ))" "$now")
  s_cpe=$(fw_state cpe "$cpe_v" "$(( !cpe_b && cpe > 0 ))" "$now")
  s_cb=$(fw_state cbund "$cbund" "$(( cbund > 0 ))" "$now")
  s_dfn=$(fw_state dfn "$dfn" "$(( dfn > 0 ))" "$now")
  # A counter that does not move while gvmd's job is still running is not a stall: gvmd spends
  # long minutes in post-processing steps (CPE matches, CVSS/EPSS updates) without new rows
  if [[ "$FW_JOBS" == *scap=run* ]]; then
    [[ "$s_cve" == stall ]] && s_cve=run
    [[ "$s_cpe" == stall ]] && s_cpe=run
  fi
  if [[ "$FW_JOBS" == *cert=run* ]]; then
    [[ "$s_cb" == stall ]] && s_cb=run
    [[ "$s_dfn" == stall ]] && s_dfn=run
  fi

  # Header: elapsed, spinner (proves the screen is refreshing), time since last change
  local spin="${G_SPIN[$(( FW_TICK % ${#G_SPIN[@]} ))]}" since
  FW_TICK=$(( FW_TICK + 1 ))
  if (( FW_LASTCHANGE == 0 )); then since="no change seen yet"
  elif (( now - FW_LASTCHANGE < 60 )); then since="last change $(( now - FW_LASTCHANGE ))s ago"
  else since="last change $(fmt_duration $(( now - FW_LASTCHANGE ))) ago"; fi
  (( FW_LOCKED )) && since+=" (some tables locked by gvmd: last known values shown)"
  printf '%sElapsed %s%s  %s  %s%s%s\n' "$c_bold" "$(fmt_duration "$elapsed")" "$c_rst" "$spin" "$c_dim" "$since" "$c_rst"

  # Scanner (ospd-openvas) and gvmd activity
  case "$vtphase" in
    "VTs loaded") printf '  %-10s %s %s\n' "Scanner" "$(fw_icon "done")" "$vtphase" ;;
    unknown)      printf '  %-10s %s %s\n' "Scanner" "$(fw_icon unknown)" "state unknown (no VT loading message in logs)" ;;
    *)            printf '  %-10s %s %s\n' "Scanner" "$(fw_icon run)" "$vtphase" ;;
  esac
  local failed=""
  [[ "$FW_JOBS" == *scap=failed* ]] && failed+=" SCAP"
  [[ "$FW_JOBS" == *cert=failed* ]] && failed+=" CERT"
  [[ "$FW_JOBS" == *nvt=failed* ]]  && failed+=" NVTs"
  if [[ -n "$failed" ]]; then printf '  %-10s %s %s\n' "gvmd" "$(fw_icon stall)" "${c_err}FAILED:${failed}${c_rst} (sudo $APP_BIN logs gvmd)"
  elif [[ -n "$activity" ]]; then printf '  %-10s %s %s\n' "gvmd" "$(fw_icon run)" "$activity"
  else printf '  %-10s %s %s\n' "gvmd" "$(fw_icon waiting)" "idle (no feed job running)"; fi

  printf '  %-10s %s %s  %s%s%s %s\n' "NVTs" "$(fw_icon "$s_nvt")" "$(fw_value nvt "$(fmt_count "$nvt")" 10 "$s_nvt")" \
    "$c_dim" "$nvt_note" "$c_rst" "$(fw_extra nvt "$s_nvt")"

  # One line per data source
  local label key val st build txt
  for label in CVEs CPEs CERT-Bund DFN-CERT; do
    case "$label" in
      CVEs)      key=cve;   val=$cve_v; st=$s_cve; build=$cve_b ;;
      CPEs)      key=cpe;   val=$cpe_v; st=$s_cpe; build=$cpe_b ;;
      CERT-Bund) key=cbund; val=$cbund; st=$s_cb;  build=0 ;;
      DFN-CERT)  key=dfn;   val=$dfn;   st=$s_dfn; build=0 ;;
    esac
    if (( val < 0 )); then txt="waiting"
    elif (( build )); then txt="building $(fmt_count "$val")"
    else txt="$(fmt_count "$val")"; fi
    [[ "$st" == stall ]] && txt+=" (stalled?)"
    printf '  %-10s %s %s  %s\n' "$label" "$(fw_icon "$st")" "$(fw_value "$key" "$txt" 26 "$st")" "$(fw_extra "$key" "$st")"
  done

  # scap2 present but nobody building it: the SCAP build was aborted (usually: disk full)
  if [[ -z "$activity" ]] && (( cve2 >= 0 )); then
    local left; left="$(scap2_leftover_bytes)" || left=0
    if (( left > 0 )); then
      printf '  %s%s%s\n' "$c_err" "SCAP build aborted: $(human "$left") left in scap2 (disk full?). Fix: sudo $APP_BIN repair-feed" "$c_rst"
      return 2
    fi
  fi
  local ooms; ooms="$(oom_kills_recent)"
  if (( ${ooms:-0} > 0 )) && [[ -n "$activity" ]]; then
    printf '  %s%s%s\n' "$c_err" "gvmd/PostgreSQL killed ${ooms}x by the OOM killer in the last hour: the import restarts forever. Give the VM 8 GB RAM (or add swap), then restart." "$c_rst"
    return 2
  fi
  [[ -n "$failed" ]] && return 2

  # Completion: no gvmd feed job running, NVT versions match, SCAP swapped in (no scap2) and
  # populated, CERT present, counters stable over 3 consecutive polls, and - after an
  # update-feed with new SCAP/CERT data - gvmd finished those jobs after the update started.
  local sig="$nvt|$cve|$cpe|$cbund|$dfn|$cve2|$dbv"
  if [[ "$sig" == "$FW_PREV" ]]; then FW_STABLE=$(( FW_STABLE + 1 )); else FW_STABLE=0; fi
  FW_PREV="$sig"
  [[ -z "$activity" ]] || return 1
  (( FW_LOCKED )) && return 1   # gvmd is busy with locked tables: certainly not finished
  (( nvt_done && cve > 0 && cpe > 0 && cve2 < 0 && cbund >= 0 && dfn >= 0 )) || return 1
  (( FW_STABLE >= 2 || FW_ONESHOT )) || return 1
  if (( ${FW_NEED_SCAP:-0} || ${FW_NEED_CERT:-0} )); then
    local since_jobs; since_jobs="$(gvmd_job_states "$FW_SINCE")" || since_jobs=""
    (( ${FW_NEED_SCAP:-0} )) && [[ "$since_jobs" != *scap=done* ]] && return 1
    (( ${FW_NEED_CERT:-0} )) && [[ "$since_jobs" != *cert=done* ]] && return 1
  fi
  return 0
}

cmd_feed_status() {
  require_root; require_compose_file; require_docker
  gvmd_running || die "gvmd is not running — start the stack first: sudo $APP_BIN start"
  local watch=0 timeout=0
  while (( $# )); do
    case "$1" in
      --watch)   watch=1 ;;
      --timeout) shift; [[ "${1:-}" =~ ^[0-9]+$ ]] || die "--timeout expects minutes"; timeout=$(( $1 * 60 )) ;;
      *) die "Unknown option: $1 (expected: --watch, --timeout <min>)" ;;
    esac
    shift
  done

  FW_START=$(date +%s); FW_PREV=""; FW_STABLE=0; FW_TICK=0; FW_LASTCHANGE=0; FW_ONESHOT=0
  declare -gA FW_LAST=() FW_CHG_T=() FW_CHANGED=() FW_DELTA=() FW_HIST=() FW_PREVCOUNT=()
  fw_init_glyphs

  if (( ! watch )); then
    FW_ONESHOT=1   # single shot: no stability requirement (only one sample)
    local rc1=0
    feed_progress_once || rc1=$?
    case "$rc1" in
      0) ok "Feed looks fully loaded — ready to scan." ;;
      2) warn "gvmd reported a failed feed import — check: sudo $APP_BIN logs gvmd"; return 1 ;;
      *) warn "Feed import in progress — follow it with: sudo $APP_BIN feed-status --watch" ;;
    esac
    return 0
  fi

  local prev_lines=0 tty=0 last_log=0 rc out
  out="$(mktemp)"
  [[ -t 1 ]] && tty=1
  if (( tty )); then
    info "Watching feed import every ${FEED_POLL}s (Ctrl+C to quit, the import keeps running)…"
    printf '\e[?25l'                                  # hide cursor
    stty -echo 2>/dev/null || true                    # keystrokes would corrupt the redraw
  fi
  restore_term() { if (( tty )); then printf '\e[?25h'; stty echo 2>/dev/null || true; fi; }
  trap 'restore_term; rm -f "$out"; echo; exit 130' INT TERM

  while :; do
    # Run in the current shell (not a pipe) so poll-to-poll state is kept
    rc=0; feed_progress_once >"$out" || rc=$?
    if (( tty )); then
      # Move back up by exactly what was drawn last time, redraw, clear anything left below
      (( prev_lines > 0 )) && printf '\e[%dA\r' "$prev_lines"
      sed $'s/$/\e[K/' "$out"
      printf '\e[J'
      prev_lines=$(wc -l <"$out")
    elif (( rc != 1 || $(date +%s) - last_log >= 300 )); then
      cat "$out"; last_log=$(date +%s)               # journald: one summary every 5 min
    fi

    if (( rc == 0 )); then
      restore_term
      rm -f "$out"; trap - INT TERM
      ok "Feed fully loaded in $(fmt_duration $(( $(date +%s) - FW_START ))) — ready to scan."
      return 0
    fi
    if (( rc == 2 )); then
      restore_term
      rm -f "$out"; trap - INT TERM
      warn "gvmd reported a failed feed import — check: sudo $APP_BIN logs gvmd"
      return 1
    fi
    if (( timeout > 0 && $(date +%s) - FW_START >= timeout )); then
      restore_term
      rm -f "$out"; trap - INT TERM
      warn "Timeout reached, import still in progress."
      return 1
    fi
    sleep "$FEED_POLL"
  done
}

# ---------- Lock / unlock (pin images by digest) ----------
image_ref_repo() {
  # registry/repo:tag -> registry/repo ; registry/repo -> unchanged
  local ref=$1 last="${1##*/}"
  if [[ "$last" == *:* ]]; then printf '%s' "${ref%:*}"; else printf '%s' "$ref"; fi
}

cmd_lock() {
  require_root; require_compose_file; require_docker
  local svc img repo digest tmp n=0
  tmp="$(mktemp)"
  {
    echo "# Generated by $APP_NAME $APP_VERSION on $(date -Is): images pinned by registry digest."
    echo "# Feed version at lock time: $(feed_version)"
    echo "# Remove with: sudo $APP_BIN unlock"
    echo "services:"
  } >"$tmp"
  while read -r svc; do
    img="$(dc_base config "$svc" 2>/dev/null | awk '$1=="image:"{print $2; exit}')" || img=""
    [[ -n "$img" ]] || continue
    if [[ "$img" == *@sha256:* ]]; then
      digest="$img"
    else
      repo="$(image_ref_repo "$img")"
      digest="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$img" 2>/dev/null \
                | grep -m1 -F "${repo}@sha256:")" || digest=""
    fi
    if [[ -z "$digest" ]]; then
      rm -f "$tmp"
      die "No registry digest for $img (image missing or not pulled from a registry) — run 'sudo $APP_BIN install' or 'update' first."
    fi
    printf '  %s:\n    image: %s\n' "$svc" "$digest" >>"$tmp"
    n=$(( n + 1 ))
  done < <(dc_base config --services)

  if is_locked; then cp -p "$GB_DIR/docker-compose.lock.yml" "$GB_DIR/docker-compose.lock.yml.$(date +%Y%m%d-%H%M%S).bak"; fi
  install -m 0640 "$tmp" "$GB_DIR/docker-compose.lock.yml"; rm -f "$tmp"
  if ! dc config --quiet; then
    rm -f "$GB_DIR/docker-compose.lock.yml"
    die "Generated lock file is invalid — removed, stack left unlocked."
  fi
  ok "Locked $n services to their current image digests."
  if [[ -f "/etc/systemd/system/$FEED_UNIT.timer" ]]; then
    remove_units "$FEED_UNIT"
    warn "Nightly feed update disabled: it would fail every night while locked (re-enable after 'unlock')."
  fi
  info "Lock file: $GB_DIR/docker-compose.lock.yml"
  info "Disabled while locked: update, update-feed, schedule-feed enable."
}

cmd_unlock() {
  require_root; require_compose_file
  if ! is_locked; then info "Stack is not locked."; return; fi
  mv "$GB_DIR/docker-compose.lock.yml" "$GB_DIR/docker-compose.lock.yml.$(date +%Y%m%d-%H%M%S).bak"
  ok "Unlocked: images follow the tags of the official compose file again (lock kept as .bak)."
}

# ---------- Offline bundle (export / import) ----------
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

# Download Docker packages + all their dependencies into $1 and index them as a local apt repo
bundle_docker_debs() {
  local dir=$1 deps p
  mkdir -p "$dir"; chmod 0755 "$dir"
  command -v apt-ftparchive >/dev/null || apt-get install -y apt-utils >/dev/null
  mapfile -t deps < <(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
                        --no-breaks --no-replaces --no-enhances "${DOCKER_PKGS[@]}" 2>/dev/null \
                      | grep -E '^[A-Za-z0-9]' | grep -v ':' | sort -u)
  (( ${#deps[@]} )) || die "Cannot resolve Docker package dependencies (is the Docker APT repository configured?)."
  info "Downloading ${#deps[@]} packages (Docker + dependencies) for $DISTRO_ID $DISTRO_CODENAME…"
  if ! ( cd "$dir" && apt-get download "${deps[@]}" >/dev/null 2>&1 ); then
    # One package without a candidate makes the batch fail: retry one by one
    for p in "${deps[@]}"; do ( cd "$dir" && apt-get download "$p" >/dev/null 2>&1 ) || warn "Skipped package without candidate: $p"; done
  fi
  ( cd "$dir" && apt-ftparchive packages . >Packages 2>/dev/null )
  ok "Docker packages bundled ($(du -sh "$dir" | cut -f1))."
}

# Install Docker from a bundled local apt repo (no network needed)
install_docker_offline() {
  local dir=$1 list
  list="$(mktemp)"; chmod 0644 "$list"
  echo "deb [trusted=yes] file:$dir ./" >"$list"
  local aptopts=(-o Dir::Etc::sourcelist="$list" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0)
  info "Installing Docker from the bundle (offline)…"
  apt-get "${aptopts[@]}" update >/dev/null
  apt-get "${aptopts[@]}" install -y --no-install-recommends "${DOCKER_PKGS[@]}"
  rm -f "$list"
  systemctl enable --now docker
  ok "Docker installed offline ($(docker --version))."
}

cmd_export_bundle() {
  require_root; require_compose_file; require_docker
  local outdir="$PWD" with_docker=0
  while (( $# )); do
    case "$1" in
      --output)      shift; outdir="${1:-}"; [[ -d "$outdir" ]] || die "--output expects an existing directory" ;;
      --with-docker) with_docker=1 ;;
      *) die "Unknown option: $1 (expected: --output <dir>, --with-docker)" ;;
    esac
    shift
  done
  outdir="$(readlink -f "$outdir")"
  detect_distro

  local imgs=() i total=0 sz
  mapfile -t imgs < <(dc_base config --images | sort -u)
  (( ${#imgs[@]} )) || die "No images found in the compose file."
  for i in "${imgs[@]}"; do
    sz="$(docker image inspect --format '{{.Size}}' "$i" 2>/dev/null)" || die "Image missing locally: $i — run 'sudo $APP_BIN install' first."
    total=$(( total + sz ))
  done
  local avail; avail="$(df -B1 --output=avail "$outdir" | tail -1 | tr -d ' ')"
  # compressed images ≈ 40-60% of their size, plus room for the final tar
  if (( avail < total * 13 / 10 )); then
    die "Not enough space in $outdir: $(human "$avail") free, ~$(human $(( total * 13 / 10 ))) needed."
  fi

  local ts name stage
  ts="$(date +%Y%m%d-%H%M%S)"; name="vasctl-bundle-$ts"
  stage="$outdir/$name"
  mkdir -m 0700 "$stage"
  CLEANUP+=("$stage")

  local gz=gzip; command -v pigz >/dev/null && gz=pigz
  info "Saving ${#imgs[@]} images ($(human "$total") uncompressed) with $gz — this takes a while…"
  docker save "${imgs[@]}" | "$gz" -c >"$stage/images.tar.gz"
  for i in "${imgs[@]}"; do printf '%s %s\n' "$i" "$(docker image inspect --format '{{.Id}}' "$i")"; done >"$stage/IMAGES"

  cp "$GB_DIR/docker-compose.yml" "$stage/docker-compose.yml"
  if is_locked; then cp "$GB_DIR/docker-compose.lock.yml" "$stage/docker-compose.lock.yml"; fi
  install -m 0755 "$APP_PATH" "$stage/vasctl.sh"
  if (( with_docker )); then bundle_docker_debs "$stage/debs"; fi

  local fv; fv="$(feed_version)"
  cat >"$stage/MANIFEST" <<EOF
type=bundle
created=$(date -Is)
created_by=$APP_NAME $APP_VERSION
source_host=$(hostname)
distro=$DISTRO_ID
codename=$DISTRO_CODENAME
arch=$(dpkg --print-architecture)
feed_version=$fv
locked=$(is_locked && echo yes || echo no)
with_docker=$(( with_docker ))
images=${#imgs[@]}
EOF
  write_sums "$stage"
  info "Packing the bundle…"
  CLEANUP+=("$outdir/$name.tar.part")
  tar -C "$outdir" -cf "$outdir/$name.tar.part" "$name"
  mv "$outdir/$name.tar.part" "$outdir/$name.tar"
  rm -rf -- "$stage"
  ( cd "$outdir" && sha256sum "$name.tar" >"$name.tar.sha256" )
  chmod 0640 "$outdir/$name.tar" "$outdir/$name.tar.sha256"

  ok "Bundle ready: $outdir/$name.tar ($(du -h "$outdir/$name.tar" | cut -f1))"
  info "Feed frozen in the bundle: $(fmt_feed_version "$fv")"
  if (( ! with_docker )); then
    warn "Docker packages not included: the target must already have Docker (add --with-docker for a fully offline install)."
  fi
  info "On the target: copy $name.tar and $name.tar.sha256, then: sudo bash vasctl.sh import-bundle $name.tar"
  info "(vasctl.sh is inside the bundle: tar -xf $name.tar $name/vasctl.sh)"
}

cmd_import_bundle() {
  require_root
  local file="" a
  for a in "$@"; do
    case "$a" in
      -y|--yes) ASSUME_YES=1 ;;
      -*) die "Unknown option: $a (expected: <bundle.tar> [-y])" ;;
      *) file="$a" ;;
    esac
  done
  [[ -n "$file" && -f "$file" ]] || die "Usage: sudo $APP_BIN import-bundle <vasctl-bundle-*.tar> [-y]"
  file="$(readlink -f "$file")"

  if [[ -f "$file.sha256" ]]; then
    ( cd "$(dirname "$file")" && sha256sum --quiet -c "$(basename "$file").sha256" ) || die "Bundle checksum mismatch ($file.sha256)."
    ok "Bundle checksum OK."
  else
    warn "No $file.sha256 next to the bundle: outer checksum not verified (inner checksums still are)."
  fi

  local need avail; need="$(stat -c %s "$file")"; avail="$(df -B1 --output=avail /var/tmp | tail -1 | tr -d ' ')"
  (( avail > need * 2 )) || die "Not enough space in /var/tmp to unpack ($(human "$avail") free, ~$(human $(( need * 2 ))) needed)."

  info "Unpacking…"
  local root tmpdir; root="$(extract_archive "$file")"; tmpdir="$(dirname "$root")"
  [[ "$tmpdir" == /var/tmp/vasctl.* ]] || die "Unexpected temp dir: $tmpdir"
  CLEANUP+=("$tmpdir")
  verify_sums "$root"
  [[ "$(manifest_get "$root/MANIFEST" type)" == bundle ]] || die "Not a $APP_NAME bundle."

  local b_distro b_code b_arch b_feed
  b_distro="$(manifest_get "$root/MANIFEST" distro)"; b_code="$(manifest_get "$root/MANIFEST" codename)"
  b_arch="$(manifest_get "$root/MANIFEST" arch)"; b_feed="$(manifest_get "$root/MANIFEST" feed_version)"
  info "Bundle: created $(manifest_get "$root/MANIFEST" created) on $(manifest_get "$root/MANIFEST" source_host), feed $(fmt_feed_version "$b_feed")"
  [[ "$b_arch" == "$(dpkg --print-architecture)" ]] || die "Architecture mismatch: bundle $b_arch, this host $(dpkg --print-architecture)."

  # Docker
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    ok "Docker already installed."
    systemctl is-active --quiet docker || systemctl start docker
  elif [[ -d "$root/debs" ]]; then
    detect_distro
    [[ "$b_distro" == "$DISTRO_ID" && "$b_code" == "$DISTRO_CODENAME" ]] \
      || die "Bundled Docker packages are for $b_distro $b_code, this host is $DISTRO_ID $DISTRO_CODENAME."
    install_docker_offline "$root/debs"
  else
    die "Docker is not installed and the bundle has no Docker packages (re-export with --with-docker)."
  fi

  if [[ -f "$GB_DIR/docker-compose.yml" ]]; then
    warn "An installation already exists in $GB_DIR: its compose file will be replaced (volumes are kept)."
    confirm_typed "import" "Continue" || { info "Cancelled."; return; }
  fi

  info "Loading images into Docker…"
  gzip -dc "$root/images.tar.gz" | docker load >/dev/null
  local ref id actual bad=0
  while read -r ref id; do
    actual="$(docker image inspect --format '{{.Id}}' "$ref" 2>/dev/null)" || actual=""
    if [[ "$actual" != "$id" ]]; then warn "Image ID mismatch for $ref"; bad=1; fi
  done <"$root/IMAGES"
  (( ! bad )) || die "Loaded images do not match the bundle manifest."
  ok "$(wc -l <"$root/IMAGES") images loaded and verified by ID."

  install -d -m 0750 "$GB_DIR"
  install -m 0640 "$root/docker-compose.yml" "$GB_DIR/docker-compose.yml"
  # Registry digests cannot be resolved offline: images were verified by ID instead
  rm -f "$GB_DIR/docker-compose.lock.yml"
  if [[ -f "$root/docker-compose.lock.yml" ]]; then
    info "The source stack was locked: images verified by ID instead (digests need registry access). Run 'lock' again once online if needed."
  fi
  install -m 0755 "$root/vasctl.sh" "$GB_DIR/vasctl.sh"
  add_user_to_docker_group
  rm -rf -- "$tmpdir"

  ok "Import complete — feed frozen at $(fmt_feed_version "$b_feed")."
  (( IN_RESTORE )) && return 0
  echo "Next steps: sudo $GB_DIR/vasctl.sh self-install   then   sudo vasctl start"
}

# ---------- Backup / restore (gvmd database + encryption keys) ----------
GVMD_KEYS_DIR="/var/lib/gvm/gvmd"   # inside the gvmd container; holds gnupg/ (credential encryption key)
BACKUP_DIR_DEFAULT="/var/backups/vasctl"

service_running() { [[ -n "$(dc ps --status running -q "$1" 2>/dev/null)" ]]; }

gvmd_version_line() {
  local v; v="$(dc exec -T gvmd gvmd --version 2>/dev/null | head -1)" || v=""
  printf '%s' "${v:-unknown}"
}

# Feed-derived schemas, rebuilt by gvmd from the feed: excluded from scan backups
FEED_SCHEMAS=(scap cert)

# Best pg_dump compression available in the pg-gvm container: zstd (PostgreSQL 16+) or gzip -9
pg_dump_compress_opt() {
  local major
  major="$(dc exec -T -u postgres pg-gvm pg_dump --version 2>/dev/null | grep -oE '[0-9]+' | head -1)" || major=0
  if (( ${major:-0} >= 16 )) \
     && dc exec -T -u postgres pg-gvm sh -c 'pg_dump -Fc -Z zstd:1 -s -d postgres >/dev/null 2>&1'; then
    echo "zstd:19"
  else
    echo "9"
  fi
}

# cmd_backup <full|scan> [options]
cmd_backup() {
  local mode="$1"; shift
  require_root; require_compose_file; require_docker
  umask 077   # every file of the backup holds secrets (process exits right after)
  local outdir="$BACKUP_DIR_DEFAULT" label=""
  while (( $# )); do
    case "$1" in
      --output) shift; outdir="${1:-}"; [[ -n "$outdir" ]] || die "--output expects a directory" ;;
      --label)  shift; label="${1:-}"; [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || die "--label: letters, digits, . _ - only" ;;
      *) die "Unknown option: $1 (expected: --output <dir>, --label <name>)" ;;
    esac
    shift
  done
  if [[ "$mode" == scan && -z "$label" ]]; then
    die "backup-scan needs a mission name: --label <client-or-mission>"
  fi
  service_running pg-gvm || die "pg-gvm is not running — start the stack first: sudo $APP_BIN start"
  service_running gvmd   || die "gvmd is not running — start the stack first: sudo $APP_BIN start"

  install -d -m 0700 "$outdir"
  outdir="$(readlink -f "$outdir")"
  local ts name stage prefix=backup
  [[ "$mode" == scan ]] && prefix=scan
  ts="$(date +%Y%m%d-%H%M%S)"; name="vasctl-$prefix${label:+-$label}-$ts"
  stage="$outdir/$name"
  ( umask 077; mkdir "$stage" )
  CLEANUP+=("$stage")

  local dump_opts=(-Fc) compress="default" sch
  if [[ "$mode" == scan ]]; then
    compress="$(pg_dump_compress_opt)"
    dump_opts+=(-Z "$compress")
    for sch in "${FEED_SCHEMAS[@]}"; do dump_opts+=(-N "$sch"); done
    info "Dumping your mission data only (feed-derived SCAP/CERT data excluded, compression $compress)…"
  else
    info "Dumping the gvmd database (targets, tasks, results, credentials, configs)…"
  fi
  dc exec -T -u postgres pg-gvm pg_dump "${dump_opts[@]}" -d gvmd >"$stage/gvmd.dump"
  [[ -s "$stage/gvmd.dump" ]] || die "Empty database dump."

  info "Saving gvmd encryption keys (required to decrypt stored scan credentials)…"
  if ! dc exec -T -u root gvmd tar -C "$GVMD_KEYS_DIR" -czf - gnupg >"$stage/gvmd-keys.tar.gz" 2>/dev/null \
     || [[ ! -s "$stage/gvmd-keys.tar.gz" ]]; then
    rm -f "$stage/gvmd-keys.tar.gz"
    warn "Could not save gvmd keys from $GVMD_KEYS_DIR/gnupg — stored credentials will NOT be usable after a restore."
  fi

  cp "$GB_DIR/docker-compose.yml" "$stage/"
  if is_locked; then cp "$GB_DIR/docker-compose.lock.yml" "$stage/"; fi
  local fv; fv="$(feed_version)"
  cat >"$stage/MANIFEST" <<EOF
type=backup
mode=$mode
excluded_schemas=$( [[ "$mode" == scan ]] && echo "${FEED_SCHEMAS[*]}" )
compression=$compress
label=$label
created=$(date -Is)
created_by=$APP_NAME $APP_VERSION
source_host=$(hostname)
gvmd_version=$(gvmd_version_line)
feed_version=$fv
locked=$(is_locked && echo yes || echo no)
keys=$( [[ -f "$stage/gvmd-keys.tar.gz" ]] && echo yes || echo no )
EOF
  write_sums "$stage"
  CLEANUP+=("$outdir/$name.tar.part")
  ( umask 077; tar -C "$outdir" -cf "$outdir/$name.tar.part" "$name" )
  mv "$outdir/$name.tar.part" "$outdir/$name.tar"
  rm -rf -- "$stage"

  ok "Backup ready: $outdir/$name.tar ($(du -h "$outdir/$name.tar" | cut -f1))"
  if [[ "$mode" == scan ]]; then
    info "Restore with: sudo $APP_BIN restore-scan $outdir/$name.tar (gvmd rebuilds SCAP/CERT from the feed afterwards)"
  fi
  warn "It contains scan credentials and their decryption key: keep it on encrypted storage (or gpg -c it before moving it)."
}

confirm_yn() {
  (( ASSUME_YES )) && return 0
  local ans=""; read -rp "$1 [y/N] " ans || return 1
  [[ "$ans" =~ ^[yY]$ ]]
}

# Extract the first x.y.z version number from a string
ver_num() { grep -oE '[0-9]+(\.[0-9]+)+' <<<"$1" | head -1 || true; }

# On a host where Greenbone is not installed / not running, get it ready for a restore
restore_bootstrap() {
  local root=$1 bundle=$2 same=$3
  if [[ ! -f "$GB_DIR/docker-compose.yml" ]]; then
    warn "No $APP_NAME installation found in $GB_DIR: installing it first."
    IN_RESTORE=1
    if [[ -n "$bundle" ]]; then
      confirm_yn "Install from the offline bundle $(basename "$bundle")?" || die "Cancelled."
      cmd_import_bundle "$bundle"
    else
      local code
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://registry.community.greenbone.net/v2/ 2>/dev/null)" || code=000
      [[ "$code" =~ ^(200|401)$ ]] \
        || die "Greenbone registry unreachable: on an offline host, add --bundle <vasctl-bundle-*.tar>."
      if (( same )); then
        [[ -f "$root/docker-compose.lock.yml" ]] \
          || die "--same-versions needs an archive made while the stack was locked ('sudo $APP_BIN lock')."
        confirm_yn "Install Greenbone with the EXACT versions of the archive (Docker + images, several GB)?" || die "Cancelled."
        GB_COMPOSE_SRC="$root/docker-compose.yml" GB_LOCK_SRC="$root/docker-compose.lock.yml" cmd_install
      else
        confirm_yn "Install Greenbone now (Docker + latest stable images, several GB)?" || die "Cancelled."
        cmd_install
      fi
    fi
  elif (( same )); then
    warn "--same-versions ignored: an installation already exists (use 'lock'/bundles to control versions)."
  fi

  if ! service_running pg-gvm || ! service_running gvmd; then
    info "Starting the stack…"
    require_docker start
    dc_up_patient >/dev/null || die "The stack did not start: sudo $APP_BIN logs <service>"
  fi
  wait_restore_ready
}

# Wait until PostgreSQL accepts connections, the gvmd role exists and gvmd runs
wait_restore_ready() {
  local t=0 limit=300
  info "Waiting for PostgreSQL and gvmd to be ready…"
  until dc exec -T -u postgres pg-gvm psql -tAq -d postgres \
          -c "SELECT 1 FROM pg_roles WHERE rolname = 'gvmd'" 2>/dev/null | grep -q 1 \
        && service_running gvmd \
        && [[ "$(gvmd_version_line)" != unknown ]]; do
    if (( t >= limit )); then die "pg-gvm/gvmd not ready after ${limit}s — check: sudo $APP_BIN logs pg-gvm gvmd"; fi
    sleep 5; t=$(( t + 5 ))
  done
  ok "Database and gvmd ready."
}

# cmd_restore <full|scan> <file> [options]
cmd_restore() {
  local mode="$1"; shift
  require_root
  local file="" force=0 watch=0 same=0 bundle="" cmdname=restore
  [[ "$mode" == scan ]] && cmdname=restore-scan
  while (( $# )); do
    case "$1" in
      -y|--yes)        ASSUME_YES=1 ;;
      --force)         force=1 ;;
      --watch)         [[ "$mode" == scan ]] || die "--watch is only for restore-scan"; watch=1 ;;
      --bundle)        shift; bundle="${1:-}"; [[ -f "$bundle" ]] || die "--bundle expects a vasctl-bundle-*.tar file"
                       bundle="$(readlink -f "$bundle")" ;;
      --same-versions) same=1 ;;
      -*) die "Unknown option: $1 (see: $APP_BIN help $cmdname)" ;;
      *)  file="$1" ;;
    esac
    shift
  done
  [[ -n "$file" && -f "$file" ]] || die "Usage: sudo $APP_BIN $cmdname <archive.tar> [options] — see: $APP_BIN help $cmdname"
  file="$(readlink -f "$file")"
  if [[ -n "$bundle" && "$same" == 1 ]]; then die "--bundle and --same-versions are exclusive (the bundle fixes the versions)."; fi

  # Validate the archive before touching anything
  local root tmpdir; root="$(extract_archive "$file")"; tmpdir="$(dirname "$root")"
  [[ "$tmpdir" == /var/tmp/vasctl.* ]] || die "Unexpected temp dir: $tmpdir"
  CLEANUP+=("$tmpdir")
  verify_sums "$root"
  [[ "$(manifest_get "$root/MANIFEST" type)" == backup ]] || die "Not a $APP_NAME backup."
  local b_mode; b_mode="$(manifest_get "$root/MANIFEST" mode)"; b_mode="${b_mode:-full}"
  if [[ "$b_mode" == scan && "$mode" != scan ]]; then
    die "This is a scan backup (no SCAP/CERT data): use 'sudo $APP_BIN restore-scan $file'."
  fi
  if [[ "$b_mode" == full && "$mode" == scan ]]; then
    warn "This is a full backup: restoring it as-is (SCAP/CERT included, no rebuild needed)."
  fi
  info "Archive: $(manifest_get "$root/MANIFEST" label) created $(manifest_get "$root/MANIFEST" created) on $(manifest_get "$root/MANIFEST" source_host)"

  # Fresh host: install (online or from a bundle) and start; otherwise just make sure it runs
  restore_bootstrap "$root" "$bundle" "$same"

  # gvmd version check: older archive -> gvmd migrates it (fine); newer archive -> needs --force
  local b_ver cur_ver b_num c_num
  b_ver="$(manifest_get "$root/MANIFEST" gvmd_version)"; cur_ver="$(gvmd_version_line)"
  b_num="$(ver_num "$b_ver")"; c_num="$(ver_num "$cur_ver")"
  info "  gvmd in archive: $b_ver"
  info "  gvmd running:    $cur_ver"
  if [[ -z "$b_num" || -z "$c_num" ]]; then
    (( force )) || die "Cannot compare gvmd versions. Re-run with --force if you are sure they are compatible."
    warn "gvmd versions not comparable: continuing (--force)."
  elif [[ "$b_num" != "$c_num" ]]; then
    if [[ "$(printf '%s\n%s\n' "$b_num" "$c_num" | sort -V | tail -1)" == "$c_num" ]]; then
      warn "Archive from an older gvmd ($b_num → $c_num): gvmd will migrate the database on start."
    elif (( force )); then
      warn "Archive from a NEWER gvmd ($b_num > $c_num): forced — the database may not work."
    else
      die "Archive from a NEWER gvmd ($b_num > $c_num): refusing (may break gvmd). Update first ('update'), or --force."
    fi
  fi
  [[ "$(manifest_get "$root/MANIFEST" keys)" == yes ]] || warn "Backup has no gvmd keys: stored credentials will be unusable."

  warn "This REPLACES the current gvmd database (targets, tasks, results, credentials) — irreversible."
  confirm_typed "restore" "Confirm restore" || { info "Cancelled."; return; }

  info "Stopping gvmd and gsad…"
  dc stop gvmd gsad >/dev/null

  if [[ -f "$root/gvmd-keys.tar.gz" ]]; then
    info "Restoring gvmd encryption keys…"
    dc run --rm --no-deps -T -u root --entrypoint sh gvmd \
      -c "rm -rf '$GVMD_KEYS_DIR/gnupg' && tar -C '$GVMD_KEYS_DIR' -xzf -" <"$root/gvmd-keys.tar.gz"
  fi

  info "Recreating the gvmd database…"
  dc exec -T -u postgres pg-gvm psql -q -v ON_ERROR_STOP=1 -d postgres \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'gvmd' AND pid <> pg_backend_pid();" \
    -c "DROP DATABASE IF EXISTS gvmd;" \
    -c "CREATE DATABASE gvmd OWNER gvmd TEMPLATE template0;" >/dev/null
  info "Restoring the dump…"
  local log; log="$(mktemp)"
  # pg_restore exits non-zero even for harmless errors (e.g. ownership comments): report, do not abort
  if ! dc exec -T -u postgres pg-gvm pg_restore -d gvmd <"$root/gvmd.dump" 2>"$log"; then
    warn "pg_restore reported $(grep -c 'ERROR' "$log" || true) error(s) — usually harmless, last ones:"
    grep 'ERROR' "$log" | tail -5 | sed 's/^/    /' >&2 || true
    warn "Check GSA after start; full log kept in $log"
  else
    rm -f "$log"
  fi

  info "Starting gvmd and gsad…"
  dc_up_patient gvmd gsad >/dev/null || die "gvmd/gsad did not start: sudo $APP_BIN logs gvmd"
  rm -rf -- "$tmpdir"
  if [[ "$b_mode" == scan ]]; then
    ok "Mission data restored (targets, credentials, configs, tasks, reports)."
    warn "gvmd now rebuilds the SCAP and CERT data from the feed (tens of minutes): CVE/CPE details in reports"
    warn "and new scans are incomplete until it finishes."
    if (( watch )); then
      sleep 20; cmd_feed_status --watch || true
    else
      info "Follow it with: sudo $APP_BIN feed-status --watch"
    fi
  else
    ok "Restore complete. gvmd may take a few minutes to re-check the feed: sudo $APP_BIN feed-status --watch"
  fi
}

# ---------- Doctor (preflight checks) ----------
DOC_FAIL=0; DOC_WARN=0
d_ok()   { printf '  %s%-5s%s %s\n' "$c_ok"   "OK"   "$c_rst" "$*"; }
d_info() { printf '  %s%-5s%s %s\n' "$c_info" "INFO" "$c_rst" "$*"; }
d_warn() { printf '  %s%-5s%s %s\n' "$c_warn" "WARN" "$c_rst" "$*"; DOC_WARN=$(( DOC_WARN + 1 )); }
d_fail() { printf '  %s%-5s%s %s\n' "$c_err"  "FAIL" "$c_rst" "$*"; DOC_FAIL=$(( DOC_FAIL + 1 )); }
d_section() { printf '\n%s%s%s\n' "$c_bold" "$1" "$c_rst"; }

# Guess whether this VM sits behind a hypervisor NAT (bad for ARP/ICMP host discovery)
detect_vm_nat() {
  local virt=$1 gw=$2
  [[ "$virt" == none ]] && return 1
  case "$gw" in
    10.0.2.1|10.0.2.2) echo "VirtualBox NAT"; return 0 ;;
    192.168.122.1)     echo "libvirt/KVM default NAT"; return 0 ;;
    192.168.64.1)      echo "UTM / Apple Virtualization shared network"; return 0 ;;
  esac
  if [[ "$virt" == vmware && "$gw" =~ \.2$ ]]; then echo "VMware NAT (vmnet8)"; return 0; fi
  if [[ "$virt" == microsoft && "$gw" =~ ^172\. ]]; then echo "Hyper-V Default Switch (NAT)"; return 0; fi
  return 1
}

cmd_doctor() {
  require_root
  DOC_FAIL=0; DOC_WARN=0

  d_section "System"
  if ( detect_distro ) >/dev/null 2>&1; then
    detect_distro
    d_ok "Distribution: ${PRETTY_NAME:-$DISTRO_ID $DISTRO_VERSION} ($DISTRO_CODENAME)"
  else
    d_fail "Unsupported distribution: $( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-${ID:-unknown}}") (Debian/Ubuntu only)"
  fi
  local arch; arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  if [[ "$arch" == amd64 ]]; then d_ok "Architecture: $arch"; else d_warn "Architecture: $arch (Greenbone images target amd64; check multi-arch support)"; fi
  local cpus; cpus="$(nproc)"
  if (( cpus >= 4 )); then d_ok "CPUs: $cpus"; else d_warn "CPUs: $cpus (4+ recommended, scans and feed import will be slow)"; fi
  local mem_gb; mem_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
  if (( mem_gb >= 7 )); then d_ok "RAM: ~${mem_gb} GB"
  elif (( mem_gb >= 4 )); then d_warn "RAM: ~${mem_gb} GB (8 GB recommended)"
  else d_fail "RAM: ~${mem_gb} GB (gvmd + PostgreSQL + scanner need 8 GB)"; fi
  local swap_kb; swap_kb="$(awk '/SwapTotal/{print $2}' /proc/meminfo)" || swap_kb=0
  if (( mem_gb < 7 && ${swap_kb:-0} == 0 )); then
    d_warn "No swap with less than 8 GB RAM: gvmd's NVT import (~2.5 GB) gets OOM-killed in a loop. Fix:"
    d_info "  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
    d_info "  echo '/swapfile none swap sw 0 0' >> /etc/fstab"
  fi
  local ooms; ooms="$(journalctl -k --since -7d --no-pager 2>/dev/null | grep -ciE 'out of memory|oom-kill' || true)"
  local ooms_h; ooms_h="$(oom_kills_recent)"
  if (( ${ooms_h:-0} > 0 )); then
    d_fail "gvmd/PostgreSQL OOM-killed ${ooms_h}x in the last hour: the feed import loops and never finishes (8 GB RAM or swap needed)"
  elif (( ${ooms:-0} > 0 )); then
    d_warn "Kernel OOM killer fired ${ooms} time(s) in 7 days (a killed gvmd/PostgreSQL leaves the feed import stuck): give the VM more RAM"
  fi
  local ntp; ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" || ntp=""
  case "$ntp" in
    yes) d_ok "Clock: NTP-synchronized" ;;
    no)  d_warn "Clock: NOT NTP-synchronized (TLS, feed signatures and scan timestamps can go wrong)" ;;
    *)   d_info "Clock: NTP status unknown (timedatectl unavailable)" ;;
  esac

  d_section "Network"
  local gw iface ip virt nat
  gw="$(ip route show default 2>/dev/null | awk '{print $3; exit}')" || gw=""
  iface="$(ip route show default 2>/dev/null | awk '{print $5; exit}')" || iface=""
  ip="$( [[ -n "$iface" ]] && ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')" || ip=""
  virt="$(systemd-detect-virt 2>/dev/null)" || true; virt="${virt:-none}"
  if [[ -z "$gw" ]]; then
    d_warn "No default route (offline host? fine for bundle use, but targets must be routable)"
  elif nat="$(detect_vm_nat "$virt" "$gw")"; then
    d_warn "Looks like $nat (gateway $gw, virt: $virt): ARP/ICMP host discovery and LAN scans will be degraded — use bridged networking"
  else
    d_ok "Interface $iface ${ip:-?} via $gw (virtualization: $virt)"
  fi
  if [[ "$virt" == oracle ]]; then
    d_info "VirtualBox guest: prefer a fixed-size disk on SSD, 8 GB RAM, bridged network; keep the VM"
    d_info "  awake during a feed import (pausing/saving the VM mid-import stretches it, see feed-status)"
  fi
  local code; code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://registry.community.greenbone.net/v2/ 2>/dev/null)" || code="000"
  if [[ "$code" =~ ^(200|401)$ ]]; then d_ok "Greenbone registry reachable (install/update possible)"
  else d_info "Greenbone registry unreachable (needed for install/update, not for an offline bundle)"; fi

  d_section "Docker"
  local docker_ok=0
  if ! command -v docker >/dev/null; then
    d_fail "Docker not installed (sudo $APP_BIN install, or import-bundle --with-docker bundle)"
  elif ! docker info >/dev/null 2>&1; then
    d_fail "Docker installed but not running (systemctl start docker)"
  else
    docker_ok=1
    d_ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
    if docker compose version >/dev/null 2>&1; then d_ok "Compose plugin $(docker compose version --short 2>/dev/null)"
    else d_fail "docker compose plugin missing"; fi
    local root avail_gb
    root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)" || root=""
    [[ -d "$root" ]] || root=/var/lib/docker
    [[ -d "$root" ]] || root=/
    avail_gb="$(df -B1 --output=avail "$root" 2>/dev/null | tail -1 | tr -dc '0-9')"
    avail_gb=$(( ${avail_gb:-0} / 1024 / 1024 / 1024 ))
    local size_gb; size_gb="$(df -B1 --output=size "$root" 2>/dev/null | tail -1 | tr -dc '0-9')" || size_gb=0
    size_gb=$(( ${size_gb:-0} / 1024 / 1024 / 1024 ))
    if (( size_gb > 0 && size_gb < 90 )); then
      d_warn "Filesystem of $root is ${size_gb} GB: a loaded stack uses ~55 GB and a SCAP update needs ~25 GB more at its peak (100 GB disk recommended)"
    fi
    if [[ -f "$GB_DIR/docker-compose.yml" ]] && gvmd_running && service_running pg-gvm; then
      local need free; need="$(feed_update_need_bytes "${FEED_SERVICES[@]}")"; free="$(docker_free_bytes)"
      if (( free >= need )); then d_ok "Free space: $(human "$free") (next feed update needs up to $(human "$need"))"
      else d_fail "Free space: $(human "$free") < $(human "$need") needed by the next feed update (new images + SCAP rebuild): update-feed will refuse"; fi
    elif (( avail_gb >= 30 )); then d_ok "Free space on $root: ${avail_gb} GB"
    elif (( avail_gb >= 15 )); then d_warn "Free space on $root: ${avail_gb} GB (installed stack + feed + database need ~55 GB)"
    else d_fail "Free space on $root: ${avail_gb} GB (too low)"; fi
    # Raw read throughput of the disk holding Docker data (O_DIRECT, 256 MB, read-only): the SCAP
    # import is I/O bound, and on a slow virtual disk with little RAM one import takes hours
    local src mbps ddbin=dd
    command -v gnudd >/dev/null && ddbin=gnudd   # Ubuntu 25.10+: uutils dd lacks iflag=direct
    src="$(findmnt -no SOURCE --target "$root" 2>/dev/null | sed 's/\[.*//')" || src=""
    if [[ -b "$src" ]]; then
      mbps="$("$ddbin" if="$src" of=/dev/null bs=1M count=256 iflag=direct 2>&1 | awk '/copied/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9.,]+$/ && $(i+1) ~ /^[MG]B\/s$/) { v = $i; sub(",", ".", v); print ($(i+1) == "GB/s" ? v * 1000 : v) + 0 } }')" || mbps=""
      if [[ "$mbps" =~ ^[0-9.]+$ ]]; then
        if (( ${mbps%.*} >= 150 )); then d_ok "Disk read speed: ~${mbps%.*} MB/s"
        else d_warn "Disk read speed: ~${mbps%.*} MB/s (slow: a SCAP import can take hours; prefer SSD-backed, fixed-size virtual disks and 8 GB RAM)"; fi
      fi
    fi
    local dang dang_b=0 id s
    dang="$(docker images -f dangling=true -q 2>/dev/null | sort -u)" || dang=""
    for id in $dang; do s="$(docker image inspect -f '{{.Size}}' "$id" 2>/dev/null)" || s=0; dang_b=$(( dang_b + ${s:-0} )); done
    if (( dang_b > 1024 ** 3 )); then
      d_warn "$(human "$dang_b") of unused (dangling) images, e.g. old feed versions: docker image prune"
    fi
  fi

  d_section "Greenbone"
  if [[ ! -f "$GB_DIR/docker-compose.yml" ]]; then
    d_warn "Not installed in $GB_DIR (sudo $APP_BIN install or import-bundle)"
  elif (( docker_ok )); then
    if is_locked; then d_info "Images locked by digest (update/update-feed disabled)"; else d_info "Images follow compose tags (not locked)"; fi
    local states core svc st health bad=() down=()
    states="$(dc ps -a --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null)" || states=""
    while read -r svc st health; do
      [[ -n "$svc" ]] || continue
      if [[ "$st" == restarting || "${health:-}" == unhealthy ]]; then bad+=("$svc"); fi
    done <<<"$states"
    for core in pg-gvm redis-server gvmd gsad ospd-openvas nginx; do
      service_running "$core" || down+=("$core")
    done
    if (( ${#bad[@]} )); then d_fail "Unhealthy or restart-looping: ${bad[*]} (sudo $APP_BIN logs <service>)"; fi
    if (( ${#down[@]} == 6 )); then
      d_info "Stack stopped"
      # Ports must be free for nginx when the stack starts
      local busy
      busy="$(ss -ltnpH '( sport = :443 or sport = :9392 )' 2>/dev/null)" || busy=""
      if [[ -n "$busy" ]]; then d_fail "Port 443/9392 already in use: $(awk '{print $4, $6}' <<<"$busy" | tr '\n' ' ')"
      else d_ok "Ports 443 and 9392 free for GSA"; fi
    elif (( ${#down[@]} )); then
      d_warn "Core services not running: ${down[*]} (sudo $APP_BIN start)"
    else
      d_ok "Core services running"
      if gsa_up; then d_ok "GSA reachable at $GB_GSA_URL"; else d_warn "GSA not reachable at $GB_GSA_URL yet"; fi
      local fv age; fv="$(feed_version)"; age="$(feed_age_days "$fv")"
      if (( age < 0 )); then d_warn "Feed version unknown (feed not loaded yet? sudo $APP_BIN feed-status)"
      elif (( age <= 7 )); then d_ok "Feed $(fmt_feed_version "$fv") (${age} days old)"
      elif (( age <= 30 )); then d_info "Feed $(fmt_feed_version "$fv") (${age} days old — frozen? update before a mission)"
      else d_warn "Feed $(fmt_feed_version "$fv") is ${age} days old: recent CVEs are missing"; fi
      local left; left="$(scap2_leftover_bytes)" || left=0
      if (( left > 0 )); then
        d_fail "Aborted SCAP build left $(human "$left") in the database (scap2), usually after a full disk: sudo $APP_BIN repair-feed"
      fi
    fi
  fi

  echo
  if (( DOC_FAIL )); then
    printf '%s%d failure(s), %d warning(s).%s\n' "$c_err" "$DOC_FAIL" "$DOC_WARN" "$c_rst"; return 1
  elif (( DOC_WARN )); then
    printf '%s0 failure, %d warning(s).%s\n' "$c_warn" "$DOC_WARN" "$c_rst"
  else
    printf '%sAll checks passed.%s\n' "$c_ok" "$c_rst"
  fi
}

# ---------- Disk usage ----------
human() { numfmt --to=iec --suffix=B --format='%.1f' "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

cmd_disk() {
  require_root
  command -v docker >/dev/null && docker info >/dev/null 2>&1 || die "Docker is not installed or not running."
  local label="com.docker.compose.project=$GB_PROJECT"
  local total=0 size id ref

  # Images: each image ID counted once (openvas-scanner backs several services).
  # Sizes include shared base layers, so the real on-disk total is a bit lower.
  info "Greenbone images:"
  local seen=" "
  while read -r id ref; do
    [[ "$seen" == *" $id "* ]] && continue
    seen+="$id "
    size="$(docker image inspect --format '{{.Size}}' "$id" 2>/dev/null || echo 0)"
    total=$(( total + size ))
    printf '  %10s  %s\n' "$(human "$size")" "$ref"
  done < <(docker images --format '{{.ID}} {{.Repository}}:{{.Tag}}' \
             | grep -E ' (registry\.community\.greenbone\.net|greenbone)/' | sort -k2)
  if (( total == 0 )); then printf '  %s\n' "(none)"; fi
  printf '  %s%10s  TOTAL images%s\n\n' "$c_bold" "$(human "$total")" "$c_rst"

  # Volumes: real usage measured with du on each mountpoint (local driver)
  info "Greenbone volumes (database, feed data, sockets…):"
  local vtotal=0 v mp
  while read -r v; do
    [[ -n "$v" ]] || continue
    mp="$(docker volume inspect --format '{{.Mountpoint}}' "$v" 2>/dev/null)" || mp=""
    if [[ -n "$mp" && -d "$mp" ]]; then size="$(du -sb "$mp" 2>/dev/null | cut -f1)"; else size=0; fi
    size=${size:-0}; vtotal=$(( vtotal + size ))
    printf '  %10s  %s\n' "$(human "$size")" "${v#"${GB_PROJECT}"_}"
  done < <(docker volume ls -q --filter "label=$label" | sort)
  if (( vtotal == 0 )); then printf '  %s\n' "(none)"; fi
  printf '  %s%10s  TOTAL volumes%s\n\n' "$c_bold" "$(human "$vtotal")" "$c_rst"

  printf '  %s%10s  GRAND TOTAL (images + volumes)%s\n\n' "$c_bold" "$(human $(( total + vtotal )))" "$c_rst"

  # Free space where Docker stores everything
  local root; root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)" || root=""
  [[ -d "$root" ]] || root=/var/lib/docker
  info "Free space on Docker storage ($root):"
  df -h --output=size,used,avail,pcent,target "$root" | sed 's/^/  /'
}

cmd_logs() {
  require_root; require_compose_file; require_docker
  dc logs -f --tail=100 "$@"
}

gvmd_running() { [[ -n "$(dc ps --status running -q gvmd 2>/dev/null)" ]]; }

# Free bytes where images and volumes live (Docker root and, with the containerd image
# store of Docker 29+, /var/lib/containerd): the smallest of the two
docker_free_bytes() {
  local root a b
  root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)" || root=""
  [[ -d "$root" ]] || root=/var/lib/docker
  [[ -d "$root" ]] || root=/
  a="$(df -B1 --output=avail "$root" 2>/dev/null | tail -1 | tr -dc '0-9')" || a=0
  if [[ -d /var/lib/containerd ]]; then
    b="$(df -B1 --output=avail /var/lib/containerd 2>/dev/null | tail -1 | tr -dc '0-9')" || b=$a
    (( ${b:-0} < ${a:-0} )) && a=$b
  fi
  printf '%s' "${a:-0}"
}

# Bytes the next feed update may need at its peak: the new feed images are pulled while the old
# ones still exist, and on a SCAP update gvmd rebuilds the whole SCAP schema in "scap2" next to
# the live one before swapping them (measured: ~24 GB of PostgreSQL data in 2026).
feed_update_need_bytes() {
  local img=0 scap id s
  for id in $(dc images -q "$@" 2>/dev/null | sort -u); do
    s="$(docker image inspect -f '{{.Size}}' "$id" 2>/dev/null)" || s=0
    img=$(( img + ${s:-0} ))
  done
  scap="$(pg_q "select coalesce(sum(pg_total_relation_size(c.oid)),0) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'scap' and c.relkind in ('r','m')")"
  [[ "$scap" =~ ^[0-9]+$ ]] || scap=0
  (( img == 0 )) && img=$(( 8 * 1024 ** 3 ))   # first run / unknown: feed images are ~8 GB
  printf '%s' $(( img + scap + 5 * 1024 ** 3 ))
}

cmd_update_feed() {
  require_root; require_compose_file; require_docker start
  require_unlocked "update-feed"
  local wait=0 force=0
  while (( $# )); do
    case "$1" in
      --wait)  wait=1 ;;
      --force) force=1 ;;
      *) die "Unknown option: $1 (expected: --wait, --force)" ;;
    esac
    shift
  done

  # One update at a time: the nightly timer and a manual run must not overwrite the volumes
  # while the other is pulling or while gvmd reads them
  exec 9>"$GB_FEED_LOCK"
  flock -n 9 || die "Another feed update is already running (lock $GB_FEED_LOCK)."

  # Keep only feed services actually defined in the compose file
  local available svc; available="$(dc config --services)"
  local feeds=()
  for svc in "${FEED_SERVICES[@]}"; do
    if grep -qx "$svc" <<<"$available"; then feeds+=("$svc"); else warn "Feed service not in compose file, skipped: $svc"; fi
  done
  (( ${#feeds[@]} )) || die "No feed service found — compare FEED_SERVICES with '$APP_BIN services'."

  # A previous SCAP build that died (disk full) leaves scap2 behind: reclaim it first
  local freed0; freed0="$(drop_scap2_leftover)" || freed0=0
  (( freed0 > 0 )) && warn "Removed an aborted SCAP build (scap2, $(human "$freed0")) left by a previous update."

  # Disk space: a feed update that fills the disk in the middle of gvmd's SCAP rebuild leaves
  # PostgreSQL and gvmd in a bad state, so check before downloading anything
  local need free
  need="$(feed_update_need_bytes "${feeds[@]}")"; free="$(docker_free_bytes)"
  if (( free < need )); then
    local msg
    msg="Free space $(human "$free") < $(human "$need") needed at the peak of a feed update (new images + SCAP rebuild)."
    if (( force )); then warn "$msg Continuing (--force)."
    else
      warn "$msg"
      warn "Grow the VM disk (and the partition/filesystem), or free space: sudo $APP_BIN disk"
      die "Feed update refused to avoid filling the disk. Override with --force."
    fi
  fi

  # Feed versions before the update (only readable while the stack runs)
  local up=0 nvt0="" scap0="" cert0="" nvt1 scap1 cert1
  if gvmd_running && service_running ospd-openvas; then
    up=1; nvt0="$(disk_nvt_version)"; scap0="$(disk_secinfo_version scap)"; cert0="$(disk_secinfo_version cert)"
  fi
  local old_ids; old_ids="$(dc images -q "${feeds[@]}" 2>/dev/null | sort -u)" || old_ids=""

  info "Pulling feed images: ${feeds[*]}"
  dc_pull_retry -q "${feeds[@]}" || die "Feed pull failed: the data already in place was not touched."
  local since; since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  info "Copying data into volumes…"
  dc_up_patient "${feeds[@]}" || die "Copying the feed into the volumes failed: sudo $APP_BIN logs ${feeds[*]}"

  # Old feed images are no longer used by any container: without this, each update leaves
  # several GB of dangling images behind and a nightly schedule fills the VM disk in days
  local new_ids id freed=0 s
  new_ids="$(dc images -q "${feeds[@]}" 2>/dev/null | sort -u)" || new_ids=""
  for id in $old_ids; do
    grep -qx "$id" <<<"$new_ids" && continue
    s="$(docker image inspect -f '{{.Size}}' "$id" 2>/dev/null)" || s=0
    if docker image rm "$id" >/dev/null 2>&1; then freed=$(( freed + ${s:-0} )); fi
  done
  (( freed > 0 )) && info "Removed previous feed images ($(human "$freed") freed)."

  if ! gvmd_running; then
    warn "gvmd is not running: the import will happen on the next '$APP_BIN start'."
    return
  fi

  local need_scap=0 need_cert=0 changed=()
  if (( up )); then
    nvt1="$(disk_nvt_version)"; scap1="$(disk_secinfo_version scap)"; cert1="$(disk_secinfo_version cert)"
    [[ "$nvt1" != "$nvt0" ]]  && changed+=("NVTs $(fmt_feed_version "$nvt0") → $(fmt_feed_version "$nvt1")")
    [[ "$scap1" != "$scap0" ]] && { need_scap=1; changed+=("SCAP $(fmt_feed_version "$scap0") → $(fmt_feed_version "$scap1")"); }
    [[ "$cert1" != "$cert0" ]] && { need_cert=1; changed+=("CERT $(fmt_feed_version "$cert0") → $(fmt_feed_version "$cert1")"); }
    if (( ${#changed[@]} == 0 )); then
      ok "No new NVT/SCAP/CERT data, nothing to import (NVTs $(fmt_feed_version "$nvt1"), SCAP $(fmt_feed_version "$scap1"), CERT $(fmt_feed_version "$cert1"))."
      return
    fi
    local c; for c in "${changed[@]}"; do info "New data: $c"; done
  fi
  ok "Feed data updated — gvmd is re-importing in the background."

  if (( wait )); then
    # The dashboard only reports "ready" once gvmd has imported these exact versions
    FW_SINCE="$since" FW_NEED_SCAP=$need_scap FW_NEED_CERT=$need_cert cmd_feed_status --watch
  else
    info "Follow-up: sudo $APP_BIN feed-status --watch"
  fi
}

# ---------- Scheduled (nightly) feed update ----------
schedule_enable() {
  require_unlocked "schedule-feed enable"
  [[ "$GB_FEED_SCHEDULE" =~ ^[[:print:]]+$ ]] || die "Invalid GB_FEED_SCHEDULE."
  case "$APP_PATH" in
    /home/*|/tmp/*|/root/*)
      warn "The timer will call $APP_PATH. If you move or delete this file, the scheduled update breaks."
      warn "Recommended: sudo $APP_PATH self-install  (the timer will then follow the installed copy)."
      ;;
  esac

  cat >"/etc/systemd/system/$FEED_UNIT.service" <<EOF
[Unit]
Description=$APP_NAME - Greenbone feed update
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
Environment="GB_DIR=$GB_DIR"
Environment="GB_PROJECT=$GB_PROJECT"
ExecStart="$APP_PATH" update-feed
EOF

  cat >"/etc/systemd/system/$FEED_UNIT.timer" <<EOF
[Unit]
Description=$APP_NAME - nightly Greenbone feed update

[Timer]
OnCalendar=$GB_FEED_SCHEDULE
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemd-analyze verify "/etc/systemd/system/$FEED_UNIT.timer" "/etc/systemd/system/$FEED_UNIT.service" 2>/dev/null \
    || warn "systemd-analyze reported issues on the units, check them."
  systemctl daemon-reload
  systemctl enable --now "$FEED_UNIT.timer"
  ok "Nightly feed update enabled ($GB_FEED_SCHEDULE)."
  schedule_status
}

schedule_disable() {
  remove_units "$FEED_UNIT"
  ok "Nightly feed update disabled."
}

schedule_status() {
  if [[ ! -f "/etc/systemd/system/$FEED_UNIT.timer" ]]; then
    info "Nightly feed update: disabled."
    return
  fi
  systemctl list-timers --all --no-pager "$FEED_UNIT.timer" || true
  echo
  info "Last runs (journald):"
  journalctl -u "$FEED_UNIT.service" -n 15 --no-pager 2>/dev/null || true
}

cmd_schedule_feed() {
  require_root
  case "${1:-status}" in
    enable)  require_compose_file; schedule_enable ;;
    disable) schedule_disable ;;
    status)  schedule_status ;;
    run)
      require_compose_file
      [[ -f "/etc/systemd/system/$FEED_UNIT.service" ]] || die "Schedule not enabled — run: sudo $APP_BIN schedule-feed enable"
      systemctl start --no-block "$FEED_UNIT.service"
      ok "Feed update triggered in the background (see: $APP_BIN schedule-feed status)."
      ;;
    *) die "Unknown action: $1 (expected: enable, disable, status, run)" ;;
  esac
}

# ---------- Repair after a failed feed import ----------
cmd_repair_feed() {
  require_root; require_compose_file; require_docker start
  service_running pg-gvm || die "PostgreSQL (pg-gvm) is not running: sudo $APP_BIN start"
  local freed=0 b id s
  b="$(drop_scap2_leftover)" || b=0
  if (( b > 0 )); then ok "Dropped an aborted SCAP build (scap2): $(human "$b") freed."; freed=$(( freed + b ))
  else info "No aborted SCAP build in the database."; fi
  for id in $(docker images -f dangling=true -q 2>/dev/null | sort -u); do
    s="$(docker image inspect -f '{{.Size}}' "$id" 2>/dev/null)" || s=0
    if docker image rm "$id" >/dev/null 2>&1; then freed=$(( freed + ${s:-0} )); fi
  done
  ok "Total freed: $(human "$freed"). Free space now: $(human "$(docker_free_bytes)")."
  info "gvmd retries the SCAP import on its own; make room first if the disk is too small (sudo $APP_BIN doctor)."
}

# ---------- Software update ----------
cmd_update() {
  require_root; require_compose_file; require_docker start
  require_unlocked "update"
  warn "SOFTWARE update of the whole stack (gvmd, gsa, ospd-openvas, pg-gvm…)."
  warn "A version upgrade may migrate the database: snapshot the VM first."
  if (( ! ASSUME_YES )); then
    local ans=""; read -rp "Continue? [y/N] " ans || true
    [[ "$ans" =~ ^[yY]$ ]] || { info "Cancelled."; return; }
  fi
  fetch_compose
  dc_pull_retry || die "Image pull failed: the running stack was not touched."
  dc_up_patient --remove-orphans || die "The updated stack did not start: sudo $APP_BIN status / logs <service>"
  docker image prune -f >/dev/null
  wait_for_gsa || true
  ok "Stack updated."
}

# ---------- Uninstall ----------
confirm_typed() {
  # Strong confirmation: the user must type the expected word (unless -y)
  local expected="$1" prompt="$2" ans
  (( ASSUME_YES )) && return 0
  read -rp "$prompt (type '$expected' to confirm): " ans || return 1
  [[ "$ans" == "$expected" ]]
}

remove_units() {
  # Disable and delete <name>.timer / <name>.service for each given unit name
  local name unit
  for name in "$@"; do
    for unit in "$name.timer" "$name.service"; do
      if [[ -f "/etc/systemd/system/$unit" ]]; then
        systemctl disable --now "$unit" 2>/dev/null || true
        rm -f "/etc/systemd/system/$unit"
      fi
    done
  done
  systemctl daemon-reload
}

remove_greenbone_stack() {
  local keep_data="$1" keep_images="${2:-0}"
  local label="com.docker.compose.project=$GB_PROJECT"

  if [[ -f "$GB_DIR/docker-compose.yml" ]]; then
    local args=(down --remove-orphans)
    (( keep_images )) || args+=(--rmi all)
    (( keep_data )) || args+=(-v)
    info "docker compose ${args[*]}"
    dc "${args[@]}" || warn "compose down failed, falling back to label-based cleanup."
  fi

  # Safety net by label (missing compose file or partial down)
  local ids
  ids="$(docker ps -aq --filter "label=$label")"
  # shellcheck disable=SC2086
  if [[ -n "$ids" ]]; then docker rm -f $ids >/dev/null; fi
  if (( ! keep_data )); then
    ids="$(docker volume ls -q --filter "label=$label")"
    # shellcheck disable=SC2086
    if [[ -n "$ids" ]]; then docker volume rm -f $ids >/dev/null; fi
  fi
  ids="$(docker network ls -q --filter "label=$label")"
  # shellcheck disable=SC2086
  if [[ -n "$ids" ]]; then docker network rm $ids >/dev/null; fi
  if (( ! keep_images )); then
    ids="$(docker images -q --filter 'reference=registry.community.greenbone.net/*/*' --filter 'reference=greenbone/*' | sort -u)"
    # shellcheck disable=SC2086
    if [[ -n "$ids" ]]; then docker rmi -f $ids >/dev/null; fi
  fi
  local removed="containers, networks" kept=()
  if (( keep_images )); then kept+=(images); else removed+=", images"; fi
  if (( keep_data )); then kept+=(volumes); else removed+=", volumes"; fi
  ok "Greenbone $removed removed${kept:+ (kept: ${kept[*]})}."
}

purge_docker() {
  # Do not purge Docker silently if non-Greenbone containers/images remain
  local others_c others_i
  others_c="$(docker ps -aq 2>/dev/null | wc -l)"
  others_i="$(docker images -q 2>/dev/null | wc -l)"
  if (( others_c + others_i > 0 )); then
    warn "Docker still holds $others_c container(s) and $others_i image(s) not belonging to Greenbone."
    confirm_typed "purge" "Remove Docker AND all of this data?" || { info "Docker kept."; return; }
  fi
  info "Uninstalling Docker…"
  systemctl disable --now docker.socket docker.service containerd.service 2>/dev/null || true
  apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || true
  apt-get autoremove -y --purge
  rm -rf /var/lib/docker /var/lib/containerd /etc/docker
  rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
  if getent group docker >/dev/null; then groupdel docker; fi
  apt-get update -qq
  ok "Docker uninstalled (repository, key, data and docker group removed)."
}

cmd_uninstall() {
  require_root
  local purge=0 keep_data=0 keep_images=0 a
  for a in "$@"; do
    case "$a" in
      --purge-docker) purge=1 ;;
      --keep-data)    keep_data=1 ;;
      --keep-images)  keep_images=1 ;;
      -y|--yes)       ASSUME_YES=1 ;;
      *) die "Unknown option: $a (expected: --purge-docker, --keep-data, --keep-images, -y)" ;;
    esac
  done
  (( purge && keep_images )) && die "--keep-images and --purge-docker are contradictory (purging Docker deletes all images)."

  warn "Greenbone uninstall will remove:"
  if (( keep_images )); then warn "  - Greenbone containers and networks (images kept)"
  else warn "  - Greenbone containers, networks and images"; fi
  (( keep_data )) || warn "  - volumes: PostgreSQL database (scan results, configs, targets) and feed — IRREVERSIBLE"
  if (( keep_data || keep_images )); then warn "  - the scheduled feed update (systemd timer) if present"
  else warn "  - $GB_DIR and the scheduled feed update (systemd timer) if present"; fi
  if (( purge )); then warn "  - Docker itself (packages, /var/lib/docker, APT repository, docker group)"; fi
  confirm_typed "uninstall" "Confirm" || { info "Cancelled."; return; }

  if command -v docker >/dev/null; then
    # A stopped daemon would leave containers, volumes and images orphaned: start it first
    require_docker start
    remove_greenbone_stack "$keep_data" "$keep_images"
  else
    warn "Docker is not installed: no containers, volumes or images to remove."
  fi
  remove_units "$FEED_UNIT" "${LEGACY_UNITS[@]}"
  rm -f /usr/local/bin/gb-feed-update.sh
  if (( keep_data || keep_images )); then
    info "$GB_DIR kept (compose file needed to reuse the $( (( keep_data )) && echo volumes || echo images ))."
    (( keep_images )) && info "Restart from scratch without downloading: sudo $APP_BIN start"
  else
    rm -rf "$GB_DIR"
  fi
  if (( purge )); then purge_docker; fi
  ok "Uninstall complete."
}

# ---------- Self install ----------
cmd_self_install() {
  require_root
  local dir="/usr/local/sbin" name="vasctl"
  while (( $# )); do
    case "$1" in
      --dir)  shift; [[ -n "${1:-}" ]] || die "--dir expects a directory"; dir="$1" ;;
      --name) shift; [[ "${1:-}" =~ ^[A-Za-z0-9._-]+$ ]] || die "--name expects a plain file name"; name="$1" ;;
      *) die "Unknown option: $1 (expected: --dir <path>, --name <name>)" ;;
    esac
    shift
  done
  local target="$dir/$name"

  [[ -d "$dir" ]] || die "Directory not found: $dir"
  if [[ "$APP_PATH" == "$(readlink -f "$target" 2>/dev/null || true)" ]]; then
    ok "$APP_NAME is already running from $target."
    return
  fi
  if [[ -e "$target" ]]; then
    if cmp -s "$APP_PATH" "$target"; then
      ok "$target is already up to date."
    else
      cp -p "$target" "$target.$(date +%Y%m%d-%H%M%S).bak"
      warn "Existing $target replaced (backup kept next to it)."
      install -m 0755 -o root -g root "$APP_PATH" "$target"
    fi
  else
    install -m 0755 -o root -g root "$APP_PATH" "$target"
    ok "Installed $APP_NAME as $target."
  fi

  # Keep the nightly feed timer (if any) pointing at the installed copy
  local svc="/etc/systemd/system/$FEED_UNIT.service"
  if [[ -f "$svc" ]] && ! grep -qxF "ExecStart=\"$target\" update-feed" "$svc"; then
    local esc; esc="$(printf '%s' "$target" | sed 's/[&|\\]/\\&/g')"
    sed -i "s|^ExecStart=.*|ExecStart=\"$esc\" update-feed|" "$svc"
    systemctl daemon-reload
    ok "Scheduled feed update now uses $target."
  fi

  case ":$PATH:" in
    *":$dir:"*) info "Usage: sudo $name <command>" ;;
    *) warn "$dir is not in your PATH: call it as sudo $target <command>" ;;
  esac
}

cmd_passwd() {
  require_root; require_compose_file; require_docker
  gvmd_running || die "gvmd is not running — start the stack first: sudo $APP_BIN start"
  local pw pw2
  read -rsp "New admin password: " pw; echo
  read -rsp "Confirm: " pw2; echo
  [[ -n "$pw" && "$pw" == "$pw2" ]] || die "Passwords empty or do not match."
  dc exec -T -u gvmd gvmd gvmd --user=admin --new-password="$pw"
  ok "Admin password updated."
}

usage() {
  banner
  cat <<EOF
Usage: sudo $APP_BIN <command> [options]
       $APP_BIN help <command>     detailed help for one command
       $APP_BIN help all           detailed help for every command

Setup
  install                    Install Docker (official repo), fetch the Greenbone compose file, pull images
  passwd                     Change the admin password
  self-install [opts]        Install this script as a system command (default: /usr/local/sbin/vasctl)

Operation
  start                      Start the stack, wait for GSA, warn if the feed is still loading
  stop                       Stop the stack (data kept)
  restart [--hard]           Restart running services (default) or full down + up (--hard)
  status                     Containers, GSA, feed version, lock state and schedule
  versions                   Image tags/digests and component versions actually running
  disk                       Disk usage: Greenbone images, volumes and free space
  logs [svc]                 Follow logs (e.g. logs gvmd)
  services                   List compose services
  doctor                     Preflight checks (system, VM NAT, NTP, ports, Docker, stack, feed age)

Feed & updates
  update-feed [--wait]       Update vulnerability data now (NVT, Notus, SCAP, CERT…)
  feed-status [--watch]      Feed import progress dashboard
  repair-feed                Clean up after a failed import (aborted SCAP build, old images)
  schedule-feed <action>     Nightly feed update via systemd timer: enable | disable | status | run
  update [-y]                Update the software (compose + all images) — snapshot first!
  lock / unlock              Pin images (and thus the feed) to their current digests / release the pin

Missions & offline
  backup [opts]              Full archive of the gvmd database + encryption keys (fast restore)
  restore <file> [opts]      Replace the database with a full backup
  backup-scan --label <m>    End-of-mission archive, smallest size (feed-derived data excluded)
  restore-scan <file>        Restore a mission archive; gvmd then rebuilds SCAP/CERT from the feed
  export-bundle [opts]       Pack images, compose and this script (+ Docker packages) for an offline host
  import-bundle <file>       Install from a bundle without Internet access

Removal
  uninstall [opts]           Remove containers, images, volumes, $GB_DIR and the feed schedule

Other
  help [command|all]         Detailed help          version       Show $APP_NAME version

Environment: see '$APP_BIN help env'
EOF
}

# Detailed help, one topic per command
help_topic() {
  local t=$1
  printf '%s%s%s\n' "$c_bold" "── $t ──" "$c_rst"
  case "$t" in
    install) cat <<EOF
Usage: sudo $APP_BIN install

First-time setup on Debian or Ubuntu.
  1. Checks the platform: distribution and release, CPU architecture, RAM, free disk.
  2. Installs Docker Engine + the compose plugin from Docker's official APT repository
     (removes conflicting distro packages such as docker.io). Skipped if already present.
  3. Adds the sudo user to the 'docker' group (root-equivalent; log out/in to apply).
  4. Downloads the official Greenbone compose file into $GB_DIR (previous one kept as .bak).
  5. Pulls every image (several GB).
Nothing is started. Next: 'start', then 'passwd'. The feed stays frozen at the pulled
version unless you run 'update-feed' or enable 'schedule-feed'.
EOF
    ;;
    passwd) cat <<EOF
Usage: sudo $APP_BIN passwd

Sets a new password for the GSA 'admin' account (prompted twice, not echoed).
The default community password is 'admin': change it right after the first start.
Requires gvmd to be running.
EOF
    ;;
    self-install) cat <<EOF
Usage: sudo $APP_BIN self-install [--dir <path>] [--name <name>]

Copies this script to a system location so it can be called from anywhere:
default /usr/local/sbin/vasctl (owner root, mode 0755 so non-root users cannot alter it).
  --dir <path>    target directory (must exist)
  --name <name>   command name (default: vasctl)
Re-running is safe: identical copies are left alone, different ones are replaced with a .bak.
If the nightly feed timer exists, it is repointed to the installed copy.
EOF
    ;;
    start) cat <<EOF
Usage: sudo $APP_BIN start

Starts the whole stack (docker compose up -d), then waits up to ${GB_START_TIMEOUT}s for GSA
to answer on $GB_GSA_URL (self-signed certificate). Warns if gvmd is still importing the
feed: scans launched before the import ends are incomplete.
GSA listens on 127.0.0.1 only. From your workstation:
  ssh -L 8443:127.0.0.1:443 <user>@<vm>   then open https://127.0.0.1:8443
EOF
    ;;
    stop) cat <<EOF
Usage: sudo $APP_BIN stop

Stops and removes the containers and network (docker compose down).
Volumes (database, feed data) and images are kept: 'start' resumes where you left off.
EOF
    ;;
    restart) cat <<EOF
Usage: sudo $APP_BIN restart [--hard]

Default (soft): restarts only the services currently running (docker compose restart).
  Fast; fixes a stuck gvmd/ospd/scanner. Does not re-read the compose file and does not
  re-run one-shot containers (feed data copies, config jobs).
--hard: full stop + start (down + up -d): recreates every container. Use it after a change
  to the compose file, the lock file or environment variables.
EOF
    ;;
    status) cat <<EOF
Usage: sudo $APP_BIN status

Shows: container states, GSA reachability, a hint on feed loading, the feed version and age
(from the scanner's plugin_feed_info.inc), whether images are locked, and the nightly
schedule state with its next run.
EOF
    ;;
    versions) cat <<EOF
Usage: sudo $APP_BIN versions

Lists images in use (repository, tag, ID, size) and the versions reported by gvmd,
ospd-openvas and openvas. Tags come from the official compose file ('stable' channel for
the software, 'latest' for feed images): the exact version depends on when you pulled.
EOF
    ;;
    disk) cat <<EOF
Usage: sudo $APP_BIN disk

Disk usage of Greenbone images (each image counted once; shared layers make the total a
slight over-estimate), of each Greenbone volume (measured with du: database, feed data…),
a grand total, and free space where Docker stores its data. Works even without the
compose file (after 'uninstall --keep-images'). Units are binary (GB = GiB).
EOF
    ;;
    logs) cat <<EOF
Usage: sudo $APP_BIN logs [service…]

Follows the last 100 log lines (Ctrl+C to quit). Without a service: all services.
Useful ones: gvmd (manager, feed import), ospd-openvas (scanner, VT loading), gsad, nginx,
pg-gvm. List services with '$APP_BIN services'.
EOF
    ;;
    services) cat <<EOF
Usage: sudo $APP_BIN services

Lists the service names defined in the compose file (for 'logs <svc>' and troubleshooting).
EOF
    ;;
    doctor) cat <<EOF
Usage: sudo $APP_BIN doctor

Read-only preflight checks, each reported OK / INFO / WARN / FAIL. Exit code 1 on any FAIL.
  System:    supported distribution, architecture, CPUs (4+), RAM (8 GB), swap, recent OOM
             kills, NTP sync.
  Network:   default route, and whether this VM sits behind a hypervisor NAT
             (VirtualBox 10.0.2.x, libvirt 192.168.122.1, UTM 192.168.64.1, VMware vmnet8,
             Hyper-V Default Switch). NAT breaks ARP/ICMP host discovery: use bridged mode.
             Greenbone registry reachability (needed for install/update only).
  Docker:    installed, running, compose plugin, disk size (100 GB recommended), free space
             vs. what the next feed update needs, leftover (dangling) images.
  Greenbone: install present, lock state, restart loops / unhealthy containers, core
             services, ports 443/9392 free (when stopped), GSA reachable, feed age.
Network checks are heuristics: a WARN is a hint, not a verdict.
EOF
    ;;
    update-feed) cat <<EOF
Usage: sudo $APP_BIN update-feed [--wait] [--force]

Pulls the latest feed images (NVTs, Notus, SCAP, CERT-Bund, DFN-CERT, report formats, data
objects, GPG keys) and copies them into the volumes; gvmd then re-imports in the background
(minutes to tens of minutes). The software itself is not touched (see 'update').
  --wait   follow the import with the 'feed-status --watch' dashboard; it only reports
           "ready" once gvmd has imported the new NVT/SCAP/CERT versions.
  --force  run even if free disk space looks too small (see below).
Safety: refuses to start when free space is below what the update needs at its peak (new
images + gvmd's SCAP rebuild next to the live data, ~35 GB in 2026); pulls are retried
(GB_PULL_RETRIES); previous feed images are removed afterwards; only one run at a time.
Disabled while the stack is locked. Run it right before a mission to start from fresh data.
EOF
    ;;
    repair-feed) cat <<EOF
Usage: sudo $APP_BIN repair-feed

Cleans up after a feed import that died, typically because the disk filled up while gvmd was
rebuilding SCAP data: drops the half-built "scap2" schema (~25 GB; the live SCAP data is not
touched) and removes dangling images such as previous feed versions. gvmd then retries the
SCAP import on its own - grow the disk first if it is too small (doctor tells).
'update-feed' performs the scap2 cleanup automatically before downloading.
EOF
    ;;
    feed-status) cat <<EOF
Usage: sudo $APP_BIN feed-status [--watch [--timeout <min>]]

Shows how far gvmd is in importing the feed. gvmd exposes no percentage, so progress is
derived from the database:
  Scanner    ospd-openvas loading VTs into redis (NVTs stay at 0 until this is done)
  gvmd       feed jobs running (SCAP, CERT, NVT import), from gvmd's start/end log messages
  NVTs       count; done when gvmd's imported feed version equals the feed on disk
             (gvmd imports NVTs only after SCAP/CERT: "queued" meanwhile is normal)
  CVEs/CPEs  counters; "building" while gvmd fills the temporary scap2 schema
  CERT-Bund / DFN-CERT counters
Icons: ✓ done, ⟳ in progress, · waiting, ! no change for ${FW_STALL}s (stalled?).
Values that changed since the previous refresh are highlighted in green with their delta.
  --watch            refresh every ${FEED_POLL}s until the import looks complete
  --timeout <min>    give up after <min> minutes (exit code 1)
Completion: no gvmd feed job running, NVT versions match, SCAP swapped in and CERT present,
stable counters. Tables locked by gvmd keep their last known value (noted in the header).
Env: FEED_POLL (seconds), FW_STALL (seconds), VAS_ASCII=1 (ASCII icons).
EOF
    ;;
    schedule-feed) cat <<EOF
Usage: sudo $APP_BIN schedule-feed enable|disable|status|run

Nightly automatic feed update with a systemd timer ($FEED_UNIT.timer), off by default.
  enable    creates the timer (default 01:00, GB_FEED_SCHEDULE to change, systemd OnCalendar
            syntax). Persistent: a run missed while the VM was off happens at next boot.
  disable   removes the timer and its service.
  status    next run, last runs (journald).
  run       triggers an update now through systemd (background).
The timer calls this script by absolute path: run 'self-install' first so it stays valid.
Refused while the stack is locked.
EOF
    ;;
    update) cat <<EOF
Usage: sudo $APP_BIN update [-y]

SOFTWARE update of the whole stack: re-downloads the official compose file, pulls every
image (gvmd, gsad, ospd-openvas, pg-gvm…, and the feed), recreates containers and prunes
dangling images. A major version can migrate the database: snapshot the VM (or 'backup')
first. Asks for confirmation unless -y. Disabled while the stack is locked.
EOF
    ;;
    lock) cat <<EOF
Usage: sudo $APP_BIN lock

Pins every service to the registry digest of the image currently on disk, in an override
file ($GB_DIR/docker-compose.lock.yml) loaded automatically on top of the compose file.
Result: the exact same software AND feed on every start, recreate or reinstall — useful to
keep a mission reproducible. While locked, update / update-feed / schedule-feed enable are
refused. Re-running 'lock' refreshes the pin (old lock kept as .bak).
Requires images pulled from the registry (they carry the digests).
EOF
    ;;
    unlock) cat <<EOF
Usage: sudo $APP_BIN unlock

Removes the lock override (kept as .bak): images follow the tags of the official compose
file again, and updates are allowed. Running containers are not changed until the next
update or 'restart --hard'.
EOF
    ;;
    backup) cat <<EOF
Usage: sudo $APP_BIN backup [--label <name>] [--output <dir>]

FULL backup: everything in the database, restorable and usable immediately.
For the smallest end-of-mission archive, see 'backup-scan'.

Creates vasctl-backup[-<label>]-<date>.tar (mode 0600) containing:
  gvmd.dump          pg_dump of the gvmd database: targets, credentials, tasks, schedules,
                     scan configs, reports and results
  gvmd-keys.tar.gz   gvmd's GnuPG key that encrypts stored credentials (without it, restored
                     credentials cannot be decrypted)
  compose (+ lock), MANIFEST (gvmd and feed versions), SHA256SUMS
  --label <name>   e.g. the client or mission name
  --output <dir>   default $BACKUP_DIR_DEFAULT (created mode 0700)
The stack must be running. The archive holds secrets: keep it on encrypted storage.
For the end of a mission, prefer 'backup-scan' (much smaller).
EOF
    ;;
    restore) cat <<EOF
Usage: sudo $APP_BIN restore <backup.tar> [--bundle <file> | --same-versions] [--force] [-y]

Restores a FULL backup (from 'backup'). Scan archives are refused: use 'restore-scan'.

Replaces the current gvmd database with a backup (irreversible, typed confirmation):
verifies checksums, compares gvmd versions, stops gvmd and gsad, restores the encryption
keys, recreates the database, runs pg_restore, starts gvmd and gsad again.
Works on a FRESH host too (see 'restore-scan' for the details): if nothing is installed,
it installs Greenbone first (online, or offline with --bundle), starts it, then restores.
  --bundle <file>    fresh offline host: install from this vasctl bundle first
  --same-versions    fresh online host: reinstall the exact image digests of the archive
                     (only if the source was locked; old digests may be gone from the registry)
  --force            allow restoring an archive made by a NEWER gvmd (may not work).
                     An archive from an older gvmd is accepted automatically: gvmd migrates it.
  -y                 no confirmation.
The feed is not part of the backup: gvmd re-checks it after start.
EOF
    ;;
    backup-scan) cat <<EOF
Usage: sudo $APP_BIN backup-scan --label <mission> [--output <dir>]

End-of-mission archive taking the least space: vasctl-scan-<mission>-<date>.tar (0600).
Keeps everything that is yours:
  targets, credentials (+ gvmd encryption key), port lists, scan configs, schedules, alerts,
  tasks, reports and results, overrides and notes.
Leaves out what the feed can rebuild: the 'scap' (CVE, CPE…) and 'cert' (CERT-Bund,
DFN-CERT) schemas, usually the bulk of the database. Compression: zstd level 19 when the
PostgreSQL in pg-gvm supports it (16+), gzip level 9 otherwise.
  --label <mission>   required (client or mission name: letters, digits, . _ -)
  --output <dir>      default $BACKUP_DIR_DEFAULT
The NVT table is kept (results reference it). The stack must be running.
Typical end of mission:
  sudo $APP_BIN backup-scan --label client-x
  sudo $APP_BIN uninstall --keep-images -y   # clean slate, nothing to re-download
EOF
    ;;
    restore-scan) cat <<EOF
Usage: sudo $APP_BIN restore-scan <scan.tar> [--bundle <file> | --same-versions] [--watch] [--force] [-y]

Restores a mission archive from 'backup-scan' (also accepts a full backup), then gvmd
rebuilds the SCAP and CERT data from the feed currently installed — tens of minutes. Until
then, CVE/CPE details in reports and new scans are incomplete.

Works on a FRESH Debian/Ubuntu where $APP_NAME never ran:
  1. checks the archive (checksums, type) before touching anything;
  2. nothing installed → installs Greenbone: online by default (latest stable images),
     or offline from --bundle; asks for confirmation unless -y;
  3. starts the stack and waits for PostgreSQL and gvmd;
  4. restores keys and database, restarts gvmd.
On a fresh host, run it as: sudo bash vasctl.sh restore-scan <scan.tar> (then self-install).
GSA accounts come from the archive: 'admin' gets back its password from the mission.

Options:
  --bundle <file>    offline fresh host: install from this vasctl bundle (frozen versions)
  --same-versions    online fresh host: reinstall the exact image digests of the archive,
                     hence the mission's gvmd AND feed (archive must come from a locked
                     stack; old digests may have been removed from the registry)
  --watch            follow the SCAP/CERT rebuild with the feed-status dashboard
  --force            allow an archive from a NEWER gvmd (may not work). An archive from an
                     older gvmd is accepted automatically: gvmd migrates it on start.
  -y                 no confirmation (install and restore)
Tip: restore on the same feed version as the mission ('lock' / bundles) to get identical
CVE data in old reports.
EOF
    ;;
    export-bundle) cat <<EOF
Usage: sudo $APP_BIN export-bundle [--output <dir>] [--with-docker]

Builds vasctl-bundle-<date>.tar (+ .sha256) to install on a host WITHOUT Internet access:
  images.tar.gz      every image of the compose file (docker save, gzip/pigz) — software
                     and feed, so the feed is frozen at its current version
  IMAGES             image reference → image ID, verified on import
  docker-compose.yml (+ lock), vasctl.sh, MANIFEST, SHA256SUMS
  --with-docker      also bundles the Docker packages and all their dependencies as a local
                     APT repository, for a target with no Docker at all. The target must run
                     the SAME distribution and release (e.g. Debian 12 → Debian 12).
  --output <dir>     destination (default: current directory). Needs ~1.3× the image size.
The database is not included (use 'backup' for that).
EOF
    ;;
    import-bundle) cat <<EOF
Usage: sudo bash vasctl.sh import-bundle <bundle.tar> [-y]

Offline installation from 'export-bundle':
  1. Verifies the outer .sha256 (if next to the bundle) and every inner checksum.
  2. Checks the architecture; installs Docker from the bundled packages if Docker is missing
     (same distribution/release required).
  3. Loads the images and verifies each image ID against the manifest.
  4. Installs the compose file in $GB_DIR and the script as $GB_DIR/vasctl.sh.
A source lock is not reapplied (registry digests cannot be resolved offline): images are
verified by ID instead. Then: self-install, start, passwd. Needs ~2× the bundle size in
/var/tmp.
EOF
    ;;
    uninstall) cat <<EOF
Usage: sudo $APP_BIN uninstall [--keep-data] [--keep-images] [--purge-docker] [-y]

Removes Greenbone: containers, networks, images, volumes, $GB_DIR and the nightly timer
(typed confirmation). Options:
  --keep-data      keep volumes (database + feed) and the compose file
  --keep-images    keep images and the compose file: a later 'start' rebuilds a clean stack
                   without downloading anything (the database is wiped)
  --purge-docker   also uninstall Docker itself (packages, /var/lib/docker, repo, group);
                   asks again if other non-Greenbone containers/images exist.
                   Incompatible with --keep-images.
  -y               no confirmation
The installed command (/usr/local/sbin/vasctl) and backups are not removed.
EOF
    ;;
    version) cat <<EOF
Usage: $APP_BIN version   (or --version)

Prints the $APP_NAME version.
EOF
    ;;
    env) cat <<EOF
Environment variables (prefix the command, e.g. sudo GB_DIR=/srv/gb $APP_BIN status):
  GB_DIR            install directory (default /opt/greenbone)
  GB_PROJECT        compose project name (default greenbone-community-edition)
  GB_COMPOSE_URL    official compose file URL
  GB_GSA_URL        URL used to check GSA (default https://127.0.0.1)
  GB_START_TIMEOUT  seconds to wait for GSA on start (default 600)
  GB_PULL_RETRIES   attempts per image pull (default 4, exponential backoff from 15 s)
  GB_DATA_COPY_TIMEOUT  max seconds for feed containers to copy data into volumes on a slow
                    disk before 'start' gives up (default 5400)
  GB_FEED_SCHEDULE  systemd OnCalendar for schedule-feed (default "*-*-* 01:00:00")
  FEED_POLL         feed-status refresh interval in seconds (default 15)
  FW_STALL          seconds without change before a counter is flagged stalled (default 600)
  VAS_THEME         dark | light (color palette), NO_COLOR=1 disables colors
  VAS_ASCII=1       ASCII icons instead of Unicode
  ASSUME_YES=1      same as -y on confirmations
Note: sudo resets most variables; pass them after sudo or use sudo -E.
EOF
    ;;
    *) die "No help for '$t'. Commands: ${HELP_TOPICS[*]}" ;;
  esac
}

HELP_TOPICS=(install passwd self-install start stop restart status versions disk logs services doctor
             update-feed feed-status repair-feed schedule-feed update lock unlock backup restore
             backup-scan restore-scan
             export-bundle import-bundle uninstall version env)

cmd_help() {
  local t="${1:-}"
  case "$t" in
    "")  usage ;;
    all) banner; for t in "${HELP_TOPICS[@]}"; do help_topic "$t"; echo; done ;;
    *)   help_topic "$t" ;;
  esac
}

case "${1:-}" in
  install)        banner; cmd_install ;;
  start)          banner; cmd_start ;;
  stop)           cmd_stop ;;
  restart)        cmd_restart "${2:-}" ;;
  status)         banner; cmd_status ;;
  logs)           shift; cmd_logs "$@" ;;
  services)       require_root; require_compose_file; require_docker; dc config --services ;;
  versions)       banner; cmd_versions ;;
  disk)           cmd_disk ;;
  doctor)         banner; cmd_doctor || exit 1 ;;
  update-feed)    shift; cmd_update_feed "$@" ;;
  repair-feed)    cmd_repair_feed ;;
  feed-status)    shift; cmd_feed_status "$@" || exit 1 ;;
  schedule-feed)  cmd_schedule_feed "${2:-status}" ;;
  update)         if [[ "${2:-}" =~ ^(-y|--yes)$ ]]; then ASSUME_YES=1; fi; banner; cmd_update ;;
  lock)           cmd_lock ;;
  unlock)         cmd_unlock ;;
  backup)         shift; cmd_backup full "$@" ;;
  restore)        shift; banner; cmd_restore full "$@" ;;
  backup-scan) shift; cmd_backup scan "$@" ;;
  restore-scan) shift; banner; cmd_restore scan "$@" ;;
  export-bundle)  shift; banner; cmd_export_bundle "$@" ;;
  import-bundle)  shift; banner; cmd_import_bundle "$@" ;;
  passwd)         cmd_passwd ;;
  self-install)   shift; cmd_self_install "$@" ;;
  uninstall)      shift; banner; cmd_uninstall "$@" ;;
  version|--version|-V) echo "$APP_NAME $APP_VERSION" ;;
  help)           shift; cmd_help "${1:-}" ;;
  -h|--help)      usage ;;
  *)              usage; exit 1 ;;
esac
