# service-health

Inventory-driven health checks for services across the homelab infrastructure. Runs as the Jenkins job `service-health` every 5 minutes and publishes any failures to the `monitoring` ntfy topic.

## Files

- `services.yaml` — the service inventory. One entry per service, tagged with a `category` and a `check_type` that selects which probe runs.
- `check.py` — reads the inventory, runs each check, prints results. CLI-runnable from any host with python3 + pyyaml + curl + dig.
- `Jenkinsfile` — pipeline that runs `check.py` and dispatches notifications by exit code.

## Supported check types

| `check_type` | What it does | Required fields |
|---|---|---|
| `http_get` | GET the URL, assert response status is in the expected list | `url`, `expected_status` (int or list of ints) |
| `stream_bytes` | Read from the URL for `duration` seconds, assert byte rate ≥ `min_bps` | `url`, `duration`, `min_bps` |
| `tcp_connect` | Open a TCP connection, assert it succeeds | `host`, `port` |
| `dns_resolve` | Query a specific DNS server, assert response includes `expected_ip` | `server`, `qname`, `expected_ip` (optional) |

All check types accept `timeout` (seconds, default per type).

## Categories

Used for grouping in alerts and for `--category` filtering.

| Category | Meaning |
|---|---|
| `public-tunnel` | Reachable from the internet via Cloudflare |
| `critical-internal` | LAN services where a failure makes large parts of debug/alerting harder (Jenkins, CoreDNS, nginx-proxy, etc.) |
| `service-internal` | Useful internal services; non-critical |
| `infra` | Backing infrastructure (databases, message queues, etc.) |

## Running ad-hoc

```bash
cd applications/service-health
python3 check.py                   # everything
python3 check.py --category public-tunnel
python3 check.py --category public-tunnel --category critical-internal
python3 check.py --inventory ./services.yaml
```

Exit codes: 0 = all passed, 1 = one or more failed, 2 = setup error.

Per-service results go to stderr (human readable). Stdout is `key=value` summary lines for downstream parsing.

## Adding a service

1. Pick a category. Add an entry to `services.yaml` in the right block, alphabetical within the category.
2. If you need a check type not listed above, implement `check_<type>(spec)` in `check.py` and register it in `CHECKERS`.
3. Run `python3 check.py` locally first to validate.
4. Commit + push. The Jenkins job picks up the new entry on its next 5-minute run.

## Why this lives here

Each directory under `services/` is a Jenkins job plus the code it runs. The Jenkinsfile uses `notifyNtfy` from a shared Jenkins library (`homelab-jenkins-lib`) that is not part of this repo, and pings a Healthchecks.io dead-man URL stored as the Jenkins credential `hc-deadman-jenkins`.
