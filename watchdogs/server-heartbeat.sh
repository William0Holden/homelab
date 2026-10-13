#!/bin/bash
# server-heartbeat.sh — foundation-level meta-watchdog.
#
# Every per-service watchdog assumes the foundations work. If cron, docker, DNS,
# or a disk dies, they all go silent at once. This script watches the foundations:
# LAN, internet, DNS, docker, cron, disk, memory, peer-watchdog liveness, critical
# containers, and backup freshness. It conservatively heals systemd-resolved, cron,
# and docker after a 2-strike threshold. Host networking is never auto-restarted
# (that could lock out remote access).
#
# Runs from a systemd timer every 2 minutes — NOT cron, since cron is one of the
# things it checks.
#
# Outputs: structured log + JSON state file + a beacon file touched on all-green.
# Modes: --dry-run (log heals, don't execute), --inject <scenario> (synthetic
# failure injection, used by the test harness without disconnecting anything).
#
# Configuration (all via environment, e.g. an EnvironmentFile= in the unit):
#   SH_LAN_GATEWAY        required: address of the LAN gateway to ping
#   SH_INTERNET_PROBES    required: space-separated public hosts to ping
#   SH_DNS_PROBES         names to resolve (default: example.com example.org)
#   SH_CRITICAL_CONTAINERS space-separated container names
#   SH_PEER_WATCHDOG_LOGS space-separated log files of watchdogs that log every run
#   SH_DISK_MOUNTS        mounts to check for >=90% usage (default: / /home)
#   SH_BACKUP_MARKERS     space-separated .last_success files written by backups
#   SH_STATE_DIR, SH_LOG_FILE, SH_HEAL_THRESHOLD, SH_WATCHDOG_STALE_SECS,
#   SH_BACKUP_STALE_DAYS

set -u

# ---- config ----
STATE_DIR="${SH_STATE_DIR:-/run/server-heartbeat}"   # root-owned; see README on /tmp
LOG_FILE="${SH_LOG_FILE:-/var/log/server-heartbeat.log}"
STATE_FILE="$STATE_DIR/state.json"
STRIKE_FILE="$STATE_DIR/strikes"
BEACON_FILE="$STATE_DIR/beacon"
HEAL_THRESHOLD="${SH_HEAL_THRESHOLD:-2}"
LAN_GATEWAY="${SH_LAN_GATEWAY:-}"
read -r -a INTERNET_PROBES <<<"${SH_INTERNET_PROBES:-}"
read -r -a DNS_PROBES <<<"${SH_DNS_PROBES:-example.com example.org}"
WATCHDOG_STALE_SECS="${SH_WATCHDOG_STALE_SECS:-1800}"  # 30 min
read -r -a CRITICAL_CONTAINERS <<<"${SH_CRITICAL_CONTAINERS:-gluetun qbittorrent jellyfin nextcloud}"
# Only watchdogs that log on EVERY run belong here: incident-only loggers are
# silent when healthy, so their silence is not a liveness signal.
read -r -a PEER_WATCHDOG_LOGS <<<"${SH_PEER_WATCHDOG_LOGS:-}"
read -r -a DISK_MOUNTS <<<"${SH_DISK_MOUNTS:-/ /home}"
# Backups write a marker only when a run fully succeeds. Check every copy, because
# a mirror-copy failure is exactly the kind of half-failure that hides.
read -r -a BACKUP_MARKERS <<<"${SH_BACKUP_MARKERS:-}"
BACKUP_STALE_DAYS="${SH_BACKUP_STALE_DAYS:-2}"

# ---- args ----
DRY_RUN=0
INJECT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --inject) INJECT="${2:-}"; shift ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--dry-run] [--inject SCENARIO]
  --dry-run     Run real checks, log heal actions instead of executing them.
  --inject SCN  Force a check to fail without touching reality. Scenarios:
                  lan_down internet_down dns_broken docker_dead cron_dead
                  watchdog_stale disk_full mem_high container_missing backup_stale
EOF
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >>"$LOG_FILE"; }

# ---- strike persistence ----
declare -A STRIKES=( [dns]=0 [docker]=0 [cron]=0 )
load_strikes() {
  [[ -f "$STRIKE_FILE" ]] || return 0
  while IFS='=' read -r k v; do
    [[ -z "$k" || "$k" == \#* ]] && continue
    STRIKES[$k]=$v
  done <"$STRIKE_FILE"
}
save_strikes() {
  if ! : >"$STRIKE_FILE" 2>/dev/null; then
    # A silent failure here means the 2-strike heal can never fire. Be loud.
    log "ERROR: cannot write $STRIKE_FILE — heal escalation disabled"; return 1
  fi
  for k in "${!STRIKES[@]}"; do echo "$k=${STRIKES[$k]}" >>"$STRIKE_FILE"; done
}

# ---- checks: each prints "PASS|FAIL|SKIP detail" and returns 0 on pass ----

check_lan() {
  [[ "$INJECT" == lan_down ]] && { echo "FAIL injected"; return 1; }
  [[ -z "$LAN_GATEWAY" ]] && { echo "SKIP SH_LAN_GATEWAY unset"; return 0; }
  local i
  for i in 1 2 3; do
    ping -c 1 -W 2 "$LAN_GATEWAY" >/dev/null 2>&1 && { echo "PASS"; return 0; }
  done
  echo "FAIL gateway unreachable"; return 1
}

check_internet() {
  [[ "$INJECT" == internet_down ]] && { echo "FAIL injected"; return 1; }
  (( ${#INTERNET_PROBES[@]} )) || { echo "SKIP SH_INTERNET_PROBES unset"; return 0; }
  local h
  for h in "${INTERNET_PROBES[@]}"; do
    ping -c 1 -W 2 "$h" >/dev/null 2>&1 && { echo "PASS"; return 0; }
  done
  echo "FAIL no internet probes reachable"; return 1
}

check_dns() {
  [[ "$INJECT" == dns_broken ]] && { echo "FAIL injected"; return 1; }
  local n
  for n in "${DNS_PROBES[@]}"; do
    getent hosts "$n" >/dev/null 2>&1 || { echo "FAIL cannot resolve $n"; return 1; }
  done
  echo "PASS"; return 0
}

check_docker() {
  [[ "$INJECT" == docker_dead ]] && { echo "FAIL injected"; return 1; }
  timeout 10 docker info >/dev/null 2>&1 && { echo "PASS"; return 0; }
  echo "FAIL docker daemon unreachable"; return 1
}

check_cron() {
  [[ "$INJECT" == cron_dead ]] && { echo "FAIL injected"; return 1; }
  systemctl is-active --quiet cron && { echo "PASS"; return 0; }
  echo "FAIL cron not active"; return 1
}

check_watchdog_liveness() {
  [[ "$INJECT" == watchdog_stale ]] && { echo "FAIL injected"; return 1; }
  local now stale=() f mt
  now=$(date +%s)
  for f in "${PEER_WATCHDOG_LOGS[@]}"; do
    [[ -f "$f" ]] || { stale+=("$(basename "$f"):missing"); continue; }
    mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    (( now - mt > WATCHDOG_STALE_SECS )) && stale+=("$(basename "$f"):$(( (now - mt) / 60 ))m")
  done
  (( ${#stale[@]} == 0 )) && { echo "PASS"; return 0; }
  echo "FAIL stale: ${stale[*]}"; return 1
}

check_disk() {
  [[ "$INJECT" == disk_full ]] && { echo "FAIL injected"; return 1; }
  local low=() used mount
  while read -r used mount; do
    used=${used%\%}
    [[ "$used" =~ ^[0-9]+$ ]] && (( used >= 90 )) && low+=("$mount=${used}%")
  done < <(df --output=pcent,target "${DISK_MOUNTS[@]}" 2>/dev/null | tail -n +2)
  (( ${#low[@]} == 0 )) && { echo "PASS"; return 0; }
  echo "FAIL ${low[*]}"; return 1
}

check_memory() {
  [[ "$INJECT" == mem_high ]] && { echo "FAIL injected"; return 1; }
  local total used swt swu pct
  read -r total used <<<"$(free -m | awk '/^Mem:/{print $2, $3}')"
  read -r swt swu   <<<"$(free -m | awk '/^Swap:/{print $2, $3}')"
  pct=$(( (used + swu) * 100 / (total + swt + 1) ))
  (( pct < 90 )) && { echo "PASS mem+swap=${pct}%"; return 0; }
  echo "FAIL mem+swap=${pct}%"; return 1
}

check_containers() {
  [[ "$INJECT" == container_missing ]] && { echo "FAIL injected"; return 1; }
  timeout 10 docker info >/dev/null 2>&1 || { echo "SKIP docker unreachable"; return 0; }
  local missing=() c running
  running=$(docker ps --format '{{.Names}}' 2>/dev/null)
  for c in "${CRITICAL_CONTAINERS[@]}"; do
    grep -qx "$c" <<<"$running" || missing+=("$c")
  done
  (( ${#missing[@]} == 0 )) && { echo "PASS"; return 0; }
  echo "FAIL missing: ${missing[*]}"; return 1
}

check_backup() {
  [[ "$INJECT" == backup_stale ]] && { echo "FAIL injected"; return 1; }
  (( ${#BACKUP_MARKERS[@]} )) || { echo "SKIP no backup markers configured"; return 0; }
  local now mt marker oldest=-1 missing=()
  now=$(date +%s)
  for marker in "${BACKUP_MARKERS[@]}"; do
    [[ -f "$marker" ]] || { missing+=("$marker"); continue; }
    mt=$(stat -c %Y "$marker" 2>/dev/null || echo 0)
    (( oldest < 0 || mt < oldest )) && oldest=$mt
  done
  (( ${#missing[@]} )) && { echo "FAIL no backup marker: ${missing[*]}"; return 1; }
  if (( now - oldest > BACKUP_STALE_DAYS * 86400 )); then
    echo "FAIL last backup $(( (now - oldest) / 86400 ))d ago"; return 1
  fi
  echo "PASS $(( (now - oldest) / 86400 ))d ago"; return 0
}

# ---- heal ----
do_heal() {
  local target="$1"
  if (( DRY_RUN )); then log "DRY-RUN would heal: $target"; return 0; fi
  case "$target" in
    systemd-resolved|cron|docker)
      if systemctl restart "$target" 2>>"$LOG_FILE"; then
        log "HEAL executed: systemctl restart $target"; return 0
      fi
      log "HEAL FAILED: systemctl restart $target"; return 1 ;;
    *) log "unknown heal target: $target"; return 1 ;;
  esac
}

# ---- main ----
main() {
  load_strikes
  declare -A RESULTS
  local checks=(lan internet dns docker cron watchdog_liveness disk memory containers backup)
  local chk out
  for chk in "${checks[@]}"; do
    out=$("check_$chk")
    RESULTS[$chk]="$out"
    log "check_$chk: $out"
  done

  # strike-and-heal for the three healable checks
  local healed=() target
  for chk in dns docker cron; do
    if [[ "${RESULTS[$chk]}" == FAIL* ]]; then
      STRIKES[$chk]=$(( STRIKES[$chk] + 1 ))
      log "strike $chk=${STRIKES[$chk]}/$HEAL_THRESHOLD"
      if (( STRIKES[$chk] >= HEAL_THRESHOLD )); then
        target="$chk"; [[ "$chk" == dns ]] && target="systemd-resolved"
        do_heal "$target" && { healed+=("$target"); STRIKES[$chk]=0; }
      fi
    else
      STRIKES[$chk]=0
    fi
  done
  save_strikes

  # JSON state
  local json_checks="{}" status reason
  for chk in "${checks[@]}"; do
    case "${RESULTS[$chk]}" in PASS*) status=pass ;; SKIP*) status=skip ;; *) status=fail ;; esac
    reason="${RESULTS[$chk]#* }"
    json_checks=$(jq --arg k "$chk" --arg s "$status" --arg r "$reason" \
      '. + {($k): {status: $s, detail: $r}}' <<<"$json_checks")
  done
  local healed_json="[]"
  (( ${#healed[@]} )) && healed_json=$(printf '%s\n' "${healed[@]}" | jq -R . | jq -s .)

  jq -n --arg ts "$(ts)" --argjson dry "$DRY_RUN" --arg inject "$INJECT" \
    --argjson checks "$json_checks" --argjson healed "$healed_json" \
    --argjson strikes "$(jq -n --argjson d "${STRIKES[dns]}" --argjson dk "${STRIKES[docker]}" --argjson c "${STRIKES[cron]}" '{dns:$d, docker:$dk, cron:$c}')" \
    '{ts:$ts, dry_run:($dry==1), inject:$inject, checks:$checks, strikes:$strikes, healed:$healed}' \
    >"$STATE_FILE"

  # beacon: touched only when no check failed
  local all_ok=1
  for chk in "${checks[@]}"; do [[ "${RESULTS[$chk]}" == FAIL* ]] && all_ok=0; done
  (( all_ok )) && touch "$BEACON_FILE" 2>/dev/null
  return 0
}

main
