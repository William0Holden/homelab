#!/bin/bash
# queue-gridlock-watchdog.sh
# Detects torrent-client gridlock: ~0 download speed with active slots full of
# stuck/peerless torrents, or DHT subsystem corruption (dht_nodes=0, seen after
# repeated VPN flaps). Removes stuck items so the *arr apps can re-search, and
# restarts the client on sustained DHT failure. Runs every 5 minutes from cron.
#
# Required environment: QBIT_URL, QBIT_USER, QBIT_PASS
# Optional: QBIT_CONTAINER, PROTECTED_TAG, LOG_FILE, STATE_DIR

set -u
: "${QBIT_URL:?set QBIT_URL (e.g. http://localhost:<webui-port>)}"
: "${QBIT_USER:?set QBIT_USER}"
: "${QBIT_PASS:?set QBIT_PASS}"
QBIT_CONTAINER="${QBIT_CONTAINER:-qbittorrent}"
PROTECTED_TAG="${PROTECTED_TAG:-keep}"   # manually curated torrents are never deleted
STATE="${STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/queue-gridlock}"
LOG="${LOG_FILE:-$STATE/queue-gridlock-watchdog.log}"
SESSION_JAR="$STATE/qbit-session"

# Thresholds
ZERO_DL_MINUTES=15            # sustained ~0 dl speed -> intervention
DHT_FAIL_MINUTES=5            # sustained dht=0 -> client restart
METADL_AGE_MINUTES=20         # metaDL with 0 peers stuck this long -> delete
STALLED_AGE_MINUTES=60        # stalledDL at 0% with 0 peers stuck this long -> delete

mkdir -p "$STATE" "$(dirname "$LOG")"
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }   # cron must NOT also redirect into $LOG (double lines)
api() { curl -s -b "$SESSION_JAR" "$QBIT_URL/api/v2/$1" "${@:2}"; }

# Auth
AUTH=$(curl -s -c "$SESSION_JAR" "$QBIT_URL/api/v2/auth/login" \
  --data-urlencode "username=$QBIT_USER" --data-urlencode "password=$QBIT_PASS")
[ "$AUTH" = "Ok." ] || { log "ERROR: client auth failed"; exit 1; }

XFER=$(api transfer/info)
[ -n "$XFER" ] || { log "ERROR: no transfer info"; exit 1; }

DL_SPEED=$(echo "$XFER" | python3 -c "import json,sys; print(json.load(sys.stdin)['dl_info_speed'])")
DHT=$(echo "$XFER" | python3 -c "import json,sys; print(json.load(sys.stdin)['dht_nodes'])")

NOW=$(date +%s)
[ -f "$STATE/zero_dl_since" ]  || echo 0 > "$STATE/zero_dl_since"
[ -f "$STATE/dht_zero_since" ] || echo 0 > "$STATE/dht_zero_since"
ZERO_SINCE=$(cat "$STATE/zero_dl_since")
DHT_SINCE=$(cat "$STATE/dht_zero_since")

# --- DHT tracking ---
if [ "$DHT" = "0" ]; then
  [ "$DHT_SINCE" = "0" ] && echo "$NOW" > "$STATE/dht_zero_since" && DHT_SINCE=$NOW
  AGE=$((NOW - DHT_SINCE))
  if [ $AGE -ge $((DHT_FAIL_MINUTES * 60)) ]; then
    log "ALERT: DHT down for ${AGE}s — restarting $QBIT_CONTAINER"
    docker restart "$QBIT_CONTAINER" >> "$LOG" 2>&1
    echo 0 > "$STATE/dht_zero_since"
    exit 0
  fi
else
  echo 0 > "$STATE/dht_zero_since"
fi

# --- Active-slot gridlock detection ---
TORRENTS_FILE="$STATE/torrents.json"
api torrents/info > "$TORRENTS_FILE"
STUCK_DB="$STATE/stuck-since.json"      # {hash: first-epoch-seen-stuck}

# Track how long each torrent has been *continuously* stuck. added_on can't be trusted
# (a torrent may sit queued for days before starting), so we keep our own first-seen
# timestamp and only delete once it has been stuck past the threshold.
DELETED=$(METADL_AGE=$((METADL_AGE_MINUTES * 60)) STALLED_AGE=$((STALLED_AGE_MINUTES * 60)) \
  NOW=$NOW TFILE=$TORRENTS_FILE DB=$STUCK_DB TAG=$PROTECTED_TAG python3 <<'PY'
import json, os
t = json.load(open(os.environ['TFILE']))
now = int(os.environ['NOW'])
metadl_age = int(os.environ['METADL_AGE'])
stalled_age = int(os.environ['STALLED_AGE'])
tag = os.environ['TAG']
dbp = os.environ['DB']
try: db = json.load(open(dbp))
except Exception: db = {}
new_db, to_del = {}, []
for x in t:
    h = x['hash']
    if tag in [s.strip() for s in x.get('tags', '').split(',')]:
        continue                          # protected: never delete
    peers = x.get('num_seeds', 0) + x.get('num_leechs', 0)
    is_metadl  = x['state'] == 'metaDL' and peers == 0
    is_stalled = x['state'] == 'stalledDL' and x['progress'] < 0.001 and peers == 0
    if not (is_metadl or is_stalled):
        continue                          # not stuck now -> dropped from db (timer resets)
    since = db.get(h, now)
    new_db[h] = since
    if now - since >= (metadl_age if is_metadl else stalled_age):
        to_del.append(h)
json.dump(new_db, open(dbp, 'w'))
print('|'.join(to_del))
PY
)

if [ -n "$DELETED" ]; then
  CNT=$(echo "$DELETED" | tr '|' '\n' | wc -l)
  log "Deleting $CNT stuck (0-peer, 0% progress) torrents"
  api torrents/delete --data-urlencode "hashes=$DELETED" --data "deleteFiles=true" -o /dev/null
fi

# --- Zero-throughput gridlock: only flag with work queued but no bytes moving ---
ACTIVE_OR_QUEUED=$(TFILE=$TORRENTS_FILE python3 -c "
import json, os
t = json.load(open(os.environ['TFILE']))
print(sum(1 for x in t if x['state'] in ('downloading','metaDL','stalledDL','queuedDL','forcedDL','allocating','checkingDL')))")

if [ "$DL_SPEED" -lt 1024 ] && [ "$ACTIVE_OR_QUEUED" -gt 0 ]; then
  [ "$ZERO_SINCE" = "0" ] && echo "$NOW" > "$STATE/zero_dl_since" && ZERO_SINCE=$NOW
  AGE=$((NOW - ZERO_SINCE))
  if [ $AGE -ge $((ZERO_DL_MINUTES * 60)) ]; then
    log "ALERT: ~0 dl speed for ${AGE}s with $ACTIVE_OR_QUEUED active/queued torrents"
    if [ "$DHT" -gt 50 ]; then
      log "DHT ok ($DHT nodes): reannounce + start all"
      api torrents/reannounce --data "hashes=all" -o /dev/null
      api torrents/start      --data "hashes=all" -o /dev/null
    else
      log "DHT degraded ($DHT nodes): restarting $QBIT_CONTAINER"
      docker restart "$QBIT_CONTAINER" >> "$LOG" 2>&1
    fi
    echo 0 > "$STATE/zero_dl_since"
  fi
else
  echo 0 > "$STATE/zero_dl_since"
fi

log "tick: dl=$((DL_SPEED/1024))KB/s dht=$DHT active_or_queued=$ACTIVE_OR_QUEUED"
