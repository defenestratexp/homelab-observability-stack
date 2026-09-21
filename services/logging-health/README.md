# logging-health

Synthetic + per-host health check for the rsyslog → Vector → Loki → Grafana logging pipeline. Runs as the Jenkins job `logging-pipeline-health` every 5 minutes and publishes failure notifications to the `monitoring` ntfy topic.

## What it checks

1. **End-to-end round-trip** — emits a unique marker via `logger` on the Jenkins agent (k3s-util, which forwards via rsyslog like every other host), waits 15 s, then queries Loki for that marker. If absent, something between rsyslog → Vector → Loki is broken.
2. **Per-host heartbeat** — every host runs a 1/min `logger -t homelab-heartbeat` cron (installed by `ansible/playbooks/configure_log_heartbeat.yml`). The check counts heartbeats per host in Loki over 5 minutes and compares against the expected host set. Any host missing means rsyslog stopped, the host is down, or the network split. Expected list is hard-coded in `check.sh` (mirror of the `local_servers` inventory group).

## Files

- `check.sh` — the check itself. Runnable standalone from any host with `curl`, `jq`, and `logger`; emits machine-readable `key=value` lines on stdout and human detail on stderr.
- `Jenkinsfile` — pipeline that invokes `check.sh`, picks an exit-code-specific ntfy notification, and short-circuits on failure.
- This README.

## Running ad-hoc

```bash
bash check.sh
echo "exit=$?"
```

Override defaults via env vars:

- `LOKI_URL` — Loki base URL (default `http://192.0.2.68:31100`)
- `WAIT_SECS` — round-trip wait window (default `15`)
- `EXPECTED_HOSTS` — space-separated list to override the baked-in default

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | All checks passed |
| 1 | Synthetic round-trip failed |
| 2 | One or more expected hosts not forwarding |
| 3 | Setup error (Loki unreachable, missing tool) |

## Why this lives here

Each directory under `services/` is a Jenkins job plus the code it runs. The Jenkinsfile uses `notifyNtfy` from a shared Jenkins library (`homelab-jenkins-lib`) that is not part of this repo; it is a thin wrapper that POSTs title/message/tags/priority to an ntfy topic.

## Future

When we expand monitoring beyond logs:

- Add scrapes of Loki / Vector `/metrics` endpoints (via Prometheus or curl + LogQL) and graph p95 query latency, ingestion rate per host, etc.
- Move the host list out of `check.sh` into a shared config (probably the same source as `local_servers` in the Ansible inventory, to avoid drift).
- Consider adding a separate stricter check for the `kubernetes` log stream (currently we only synthetic-test syslog).
