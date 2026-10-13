#!/bin/bash
# port-forward-watchdog.sh — defends the torrent client's port-forwarding pipeline.
# Runs every 10 minutes from cron. Three failure modes covered:
#
#   A. EMPTY/STALE PORT — the VPN container's NAT-PMP request fails and its
#      forwarded_port file is empty or "0". The client can't accept incoming
#      peers. Heal: restart the VPN container + recreate the client.
#
#   B. PORT DRIFT — the VPN container has a port but the client's listen_port
#      doesn't match it (typical after a VPN restart without a client recreate).
#      Heal: sync via the client's API, no container restart needed.
#
#   C. FIREWALLED — ports match, but the client reports connection_status=firewalled.
#      Before healing, an external reachability check is performed. If the port IS
#      reachable, "firewalled" is a false positive from a NAT-PMP lease renewal, so
#      we only reannounce. Restart only if the port is genuinely unreachable.
#
# A and C use a 2-strike threshold (one cron interval apart) to avoid acting during
# the normal post-restart negotiation window. B fires immediately (cheap API call).
#
# Required environment (e.g. from an .env file sourced by the cron wrapper):
#   COMPOSE_DIR, QBIT_URL, QBIT_USER, QBIT_PASS
# Optional: VPN_CONTAINER, QBIT_CONTAINER, PORTCHECK_URL, LOG_FILE, STATE_DIR

set -u
: "${COMPOSE_DIR:?set COMPOSE_DIR}"
: "${QBIT_URL:?set QBIT_URL (e.g. http://localhost:<webui-port>)}"
: "${QBIT_USER:?set QBIT_USER}"
: "${QBIT_PASS:?set QBIT_PASS}"
VPN_CONTAINER="${VPN_CONTAINER:-gluetun}"
QBIT_CONTAINER="${QBIT_CONTAINER:-qbittorrent}"
PORTCHECK_URL="${PORTCHECK_URL:-}"   # optional external port-check API
LOG_FILE="${LOG_FILE:-$COMPOSE_DIR/logs/port-forward-watchdog.log}"
STATE_DIR="${STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/port-forward-watchdog}"
STATE_FILE="$STATE_DIR/strikes"
SESSION_JAR="$STATE_DIR/qbit-session"
CONSECUTIVE_FAIL_THRESHOLD=2

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

qbit_login() {
    curl -s -c "$SESSION_JAR" "$QBIT_URL/api/v2/auth/login" \
        --data-urlencode "username=$QBIT_USER" --data-urlencode "password=$QBIT_PASS" \
        -o /dev/null 2>&1
}

json_field() {  # json_field <key> <default>
    python3 -c 'import sys,json
try: print(json.load(sys.stdin)[sys.argv[1]])
except Exception: print(sys.argv[2])' "$1" "$2" 2>/dev/null
}

get_conn_status()      { curl -s -b "$SESSION_JAR" "$QBIT_URL/api/v2/transfer/info"   | json_field connection_status unknown; }
get_qbit_listen_port() { curl -s -b "$SESSION_JAR" "$QBIT_URL/api/v2/app/preferences" | json_field listen_port 0; }
get_vpn_port()         { docker exec "$VPN_CONTAINER" cat /tmp/gluetun/forwarded_port 2>/dev/null; }

set_qbit_listen_port() {
    local payload="{\"listen_port\": $1, \"random_port\": false, \"upnp\": false}"
    curl -s -b "$SESSION_JAR" "$QBIT_URL/api/v2/app/setPreferences" \
        --data-urlencode "json=$payload" -o /dev/null 2>&1
}

reannounce_all() {
    curl -s -b "$SESSION_JAR" "$QBIT_URL/api/v2/torrents/reannounce" \
        --data "hashes=all" -o /dev/null 2>&1
}

# Returns 0 if port $1 is reachable on the VPN exit address, 1 otherwise.
# Without a configured checker we can't prove reachability, so assume unreachable.
port_reachable_externally() {
    [ -z "$PORTCHECK_URL" ] && return 1
    local port=$1 exit_ip result
    exit_ip=$(docker exec "$VPN_CONTAINER" cat /tmp/gluetun/ip 2>/dev/null)
    [ -z "$exit_ip" ] && return 1
    result=$(curl -s --max-time 8 "$PORTCHECK_URL" \
        -H "Content-Type: application/json" \
        -d "{\"host\":\"$exit_ip\",\"ports\":[$port]}" 2>/dev/null | \
        python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print('yes' if d.get('check',[{}])[0].get('status') else 'no')
except Exception: print('no')" 2>/dev/null)
    [ "$result" = "yes" ]
}

heal_full() {
    local reason=$1
    log "HEAL ($reason): restart $VPN_CONTAINER + force-recreate $QBIT_CONTAINER"
    (cd "$COMPOSE_DIR" && docker compose restart "$VPN_CONTAINER" >> "$LOG_FILE" 2>&1)
    # Wait up to 90s for the VPN container to obtain a forwarded port
    local waited=0 p
    while [ $waited -lt 90 ]; do
        sleep 5; waited=$((waited+5))
        p=$(get_vpn_port)
        if [ -n "$p" ] && [ "$p" != "0" ]; then
            log "  VPN acquired a forwarded port after ${waited}s"; break
        fi
    done
    # The client shares the VPN container's network namespace; after a VPN restart
    # its netns reference is stale, so it must be recreated, not just restarted.
    (cd "$COMPOSE_DIR" && docker compose up -d --force-recreate "$QBIT_CONTAINER" >> "$LOG_FILE" 2>&1)
    sleep 15
    qbit_login
    local new_fp
    new_fp=$(get_vpn_port)
    if [ -n "$new_fp" ] && [ "$new_fp" != "0" ]; then
        set_qbit_listen_port "$new_fp"
        sleep 2
        reannounce_all
        log "  synced client listen_port to the new forwarded port"
    fi
    log "HEAL done. status=$(get_conn_status)"
}

# ---- main ----

running=$(docker ps --format '{{.Names}}')
grep -qx "$VPN_CONTAINER"  <<<"$running" || { log "$VPN_CONTAINER not running; deferring to VPN watchdog"; exit 0; }
grep -qx "$QBIT_CONTAINER" <<<"$running" || { log "$QBIT_CONTAINER not running; deferring to client watchdog"; exit 0; }

FP=$(get_vpn_port)
PREV=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
qbit_login
LP=$(get_qbit_listen_port)
STATUS=$(get_conn_status)

# --- A. Empty/0 forwarded port ---
if [ -z "$FP" ] || [ "$FP" = "0" ]; then
    NEW=$((PREV + 1)); echo "$NEW" > "$STATE_FILE"
    log "no forwarded port (strike $NEW/$CONSECUTIVE_FAIL_THRESHOLD), status=$STATUS"
    if [ "$NEW" -ge "$CONSECUTIVE_FAIL_THRESHOLD" ]; then
        heal_full "empty-port"; echo 0 > "$STATE_FILE"
    fi
    exit 0
fi

# --- B. Port drift (cheap fix, no restart) ---
if [ -n "$LP" ] && [ "$LP" != "0" ] && [ "$LP" != "$FP" ]; then
    log "PORT DRIFT: VPN port != client listen_port — syncing via API"
    set_qbit_listen_port "$FP"
    sleep 2
    reannounce_all
fi

# --- C. Firewalled despite a valid port ---
if [ "$STATUS" = "firewalled" ]; then
    NEW=$((PREV + 1)); echo "$NEW" > "$STATE_FILE"
    log "firewalled (strike $NEW/$CONSECUTIVE_FAIL_THRESHOLD)"
    if [ "$NEW" -ge "$CONSECUTIVE_FAIL_THRESHOLD" ]; then
        if port_reachable_externally "$FP"; then
            log "  port is externally reachable — false positive (lease renewal). reannouncing only."
            reannounce_all
        else
            log "  port confirmed unreachable — proceeding with heal."
            heal_full "firewalled"
        fi
        echo 0 > "$STATE_FILE"
    fi
    exit 0
fi

# Healthy
[ "$PREV" -gt 0 ] && log "recovered: status=$STATUS"
echo 0 > "$STATE_FILE"
