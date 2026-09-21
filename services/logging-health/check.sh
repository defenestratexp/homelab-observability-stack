#!/bin/bash
# Logging-pipeline health check — runs against a live Loki instance and
# verifies (1) end-to-end syslog round-trip and (2) per-host forwarding.
#
# Designed to be invoked from a Jenkinsfile but also runnable from the CLI
# (k3s-util, workstation, anywhere that can curl the Loki NodePort and run
# `logger`).
#
# Exit codes:
#   0  all checks passed
#   1  synthetic round-trip failed
#   2  one or more expected hosts not forwarding
#   3  setup error (curl/jq missing, Loki unreachable)
#
# Output: machine-readable "<key>=<value>" lines on stdout for downstream
# notification logic to consume. Human-readable detail goes to stderr.

set -u

LOKI="${LOKI_URL:-http://192.0.2.68:31100}"
WAIT_SECS="${WAIT_SECS:-15}"

# Hosts we expect to be forwarding. Mirrors the `local_servers` group in
# ansible/inventory/hosts.yml; keep in sync if hosts are added/removed there.
DEFAULT_EXPECTED="k3s-util nas media-worker radio-host k3s-main workstation pve2 edge db-host spare-host stream-host laptop jenkins-node-1 jenkins-node-2"
EXPECTED="${EXPECTED_HOSTS:-$DEFAULT_EXPECTED}"

require() {
    command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 not in PATH" >&2; exit 3; }
}
require curl
require jq
require logger

# Quick reachability probe so we fail fast with a clear error.
if ! curl -fsS -m 5 "$LOKI/ready" >/dev/null 2>&1; then
    echo "ERROR: Loki not reachable at $LOKI" >&2
    echo "loki_reachable=false"
    exit 3
fi
echo "loki_reachable=true"

# ---------- Check 1: synthetic syslog round-trip ----------

MARKER="homelab-health-$(date +%s)-$$-$RANDOM"
logger -t loki-health "$MARKER"
echo "synthetic_marker=$MARKER" >&2

# Wait for the message to traverse rsyslog → Vector → Loki.
sleep "$WAIT_SECS"

# Loki LogQL query: any line in syslog containing our marker.
QUERY='{source_type="syslog"} |= "'$MARKER'"'
ENCODED=$(jq -rn --arg q "$QUERY" '$q | @uri')
RESPONSE=$(curl -fsS -m 10 "$LOKI/loki/api/v1/query?query=$ENCODED&limit=5" 2>/dev/null || echo '{"data":{"result":[]}}')
HITS=$(echo "$RESPONSE" | jq '[.data.result[].values[]] | length')

echo "synthetic_round_trip_hits=$HITS"
if [ "$HITS" = "0" ]; then
    echo "FAIL: synthetic marker $MARKER not found in Loki after ${WAIT_SECS}s" >&2
    SYNTHETIC_OK=0
else
    echo "OK: synthetic marker round-tripped (hits=$HITS)" >&2
    SYNTHETIC_OK=1
fi

# ---------- Check 2: per-host heartbeat ----------

# Each host runs an Ansible-deployed /etc/cron.d/homelab-heartbeat that fires
# `logger -t homelab-heartbeat "alive"` every minute (see
# ansible/playbooks/configure_log_heartbeat.yml). We look for that
# heartbeat in Loki over a 5-min window — should see ~5 messages per host.
# This is a deterministic liveness signal independent of how chatty each
# host's normal workload happens to be: a previous incarnation of this
# check counted ANY syslog activity per host and false-fired on quiet
# boxes (MX Linux, Proxmox) that genuinely have multi-minute idle windows.
RANGE_QUERY='sum by (host) (count_over_time({source_type="syslog"} | json | __error__="" | appname="homelab-heartbeat" [5m]))'
ENCODED=$(jq -rn --arg q "$RANGE_QUERY" '$q | @uri')
RESPONSE=$(curl -fsS -m 10 "$LOKI/loki/api/v1/query?query=$ENCODED" 2>/dev/null || echo '{"data":{"result":[]}}')

# Collect hosts that have heartbeated in the window.
SEEN_HOSTS=$(echo "$RESPONSE" | jq -r '.data.result[].metric.host // empty' | sort -u | tr '\n' ' ')
echo "hosts_heartbeating=${SEEN_HOSTS% }"

# Compare to expected set; report any expected host that wasn't seen.
MISSING=""
for h in $EXPECTED; do
    if ! echo " $SEEN_HOSTS " | grep -q " $h "; then
        MISSING="$MISSING $h"
    fi
done
MISSING="${MISSING# }"
echo "hosts_missing=${MISSING}"

if [ -n "$MISSING" ]; then
    echo "FAIL: expected hosts not heartbeating: $MISSING" >&2
    HOSTS_OK=0
else
    echo "OK: all $(echo $EXPECTED | wc -w) expected hosts are heartbeating" >&2
    HOSTS_OK=1
fi

# ---------- Roll up exit code ----------

if [ "$SYNTHETIC_OK" = "0" ]; then
    exit 1
fi
if [ "$HOSTS_OK" = "0" ]; then
    exit 2
fi
exit 0
