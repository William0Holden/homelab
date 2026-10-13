# Watchdogs

The homelab runs roughly 30 small cron/systemd watchdogs. Each one exists because a
specific failure happened at least once and nothing caught it. These four are
representative. They've been cleaned up for publication: hostnames, addresses,
paths and credentials all come from environment variables.

All of them follow the same rules:

- **Detect the real symptom, not a proxy for it.** Check that traffic actually
  flows, not that a status file exists.
- **Strike before you heal.** Most heals need two consecutive failures, so a
  transient blip or a normal reconnect window doesn't cause a restart.
- **Prefer the cheapest fix.** Sync a setting over the API before restarting a
  container; restart a container before touching the host.
- **Stay in your lane.** If a dependency is down, log it and defer to the watchdog
  that owns it.

| Script | Schedule | What it catches |
|---|---|---|
| [`server-heartbeat.sh`](server-heartbeat.sh) | systemd timer, every 2 min | The foundations every other watchdog assumes: LAN, internet, DNS, docker, cron, disk, memory, critical containers, backup freshness, and whether the *other* watchdogs are still logging. Heals only `systemd-resolved`, `cron`, and `docker`, and never host networking. It runs from systemd rather than cron so it still works when cron is dead. Has `--dry-run` and `--inject <scenario>` modes for a fault-injection test harness. |
| [`vpn-monitor.sh`](vpn-monitor.sh) | cron, every 5 min | VPN container that is "running" but not passing traffic. Does a live egress request through the tunnel, then a real restart, then recreates the torrent client that shares the VPN's network namespace. |
| [`port-forward-watchdog.sh`](port-forward-watchdog.sh) | cron, every 10 min | The VPN tunnel is up but the forwarded port silently died. Covers three cases: empty port (full heal), port drift between VPN and client (API sync only), and "firewalled" status (checks external reachability first, because NAT-PMP lease renewals cause false positives). |
| [`queue-gridlock-watchdog.sh`](queue-gridlock-watchdog.sh) | cron, every 5 min | Download slots filled with peerless torrents that will never start, or a corrupted DHT (`dht_nodes=0`) after repeated VPN flaps. Tracks its own "first seen stuck" time per torrent instead of trusting `added_on`, and never touches torrents tagged `keep`. |

## Notes

- **Log once.** If a script writes to its own log, cron must not *also* redirect
  stdout into that log, or every line appears twice.
- **State under `/tmp` is a trap for watchdogs that run as root.** With
  `fs.protected_regular=2`, even root can't write-open a file in sticky `/tmp`
  that another user owns. One stale user-owned strikes file silently disabled
  heal escalation for five weeks. Keep state in a directory each invoker owns
  (`/run/...`, `$XDG_RUNTIME_DIR`), and log loudly if a state write fails.
- **Deletion paths need circuit breakers.** If an automation suddenly sees every
  item as an orphan, the problem is almost always a broken connection, not real
  orphans. Skip that run and leave the items alone.
