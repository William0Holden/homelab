#!/bin/bash
# vpn-monitor.sh — verifies the VPN container actually carries traffic, and
# recovers it when it doesn't. Runs every 5 minutes from cron.
#
# The earlier version of this script read the VPN container's cached exit-IP file
# and reported "healthy" for an entire 36-hour outage: the file survives a dead
# tunnel. It also "restarted" with `docker compose up -d`, which is a no-op for a
# container that is still running. This version does a live egress test and a
# real restart, then recreates the namespace-sharing client.
#
# Required environment: COMPOSE_DIR, EGRESS_CHECK_URL
# Optional: VPN_CONTAINER, QBIT_CONTAINER, LOG_FILE

set -u
: "${COMPOSE_DIR:?set COMPOSE_DIR}"
VPN_CONTAINER="${VPN_CONTAINER:-gluetun}"
QBIT_CONTAINER="${QBIT_CONTAINER:-qbittorrent}"
EGRESS_CHECK_URL="${EGRESS_CHECK_URL:?set EGRESS_CHECK_URL (any what-is-my-IP endpoint)}"
LOG_FILE="${LOG_FILE:-$COMPOSE_DIR/logs/vpn-monitor.log}"
MAX_LOG_SIZE=10485760  # 10MB

mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt $MAX_LOG_SIZE ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
    fi
}

# Live check: container health AND an actual request through the tunnel right now.
check_vpn() {
    local health
    health=$(docker inspect --format='{{.State.Health.Status}}' "$VPN_CONTAINER" 2>/dev/null)
    [ "$health" = "healthy" ] || return 1
    docker exec "$VPN_CONTAINER" sh -c "wget -qO- --timeout=8 '$EGRESS_CHECK_URL'" >/dev/null 2>&1
}

restart_containers() {
    log "VPN check failed — force-restarting $VPN_CONTAINER"
    (cd "$COMPOSE_DIR" && docker compose restart "$VPN_CONTAINER")
    sleep 30
    if check_vpn; then
        # The client uses network_mode: service:<vpn>; its netns reference is now stale.
        (cd "$COMPOSE_DIR" && docker compose up -d --force-recreate "$QBIT_CONTAINER")
        log "VPN reconnected; $QBIT_CONTAINER recreated against the fresh VPN container"
    else
        log "ERROR: VPN failed to reconnect after restart"
    fi
}

rotate_log
if check_vpn; then
    log "VPN is connected and passing traffic"
else
    log "WARNING: VPN is not passing traffic"
    restart_containers
fi
