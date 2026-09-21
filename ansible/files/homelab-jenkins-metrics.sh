#!/bin/bash
# Publish Jenkins controller health as node_exporter textfile metrics.
#
# Why this exists: Jenkins has no Prometheus plugin installed, and both of the
# existing Jenkins health checks (service-health, logging-pipeline-health) run
# ON a Jenkins agent — so when every agent is offline they cannot run, and the
# only monitoring that stays green is an HTTP check against /login, which the
# controller serves perfectly while the whole build pipeline is dead. That is
# exactly what happened on 2026-09-14: both agents offline, 655 builds queued,
# every monitor green.
#
# This runs from cron on the controller host instead, so it keeps reporting
# regardless of agent state.
#
# Output: /var/lib/node_exporter/textfile_collector/homelab_jenkins.prom
set -uo pipefail

OUT_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
OUT="${OUT_DIR}/homelab_jenkins.prom"
TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# shellcheck disable=SC1091
[ -r /etc/homelab/jenkins-api.env ] && . /etc/homelab/jenkins-api.env
JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"

emit() { printf '%s\n' "$1" >> "$TMP"; }

api() {
    # -g (--globoff) is REQUIRED: Jenkins tree= parameters contain [ ] which
    # curl otherwise parses as a glob range, failing the request. With -sf the
    # error is swallowed and the function just returns empty, which silently
    # looked like "Jenkins is down".
    curl -sfg --max-time 10 -u "${JENKINS_USER}:${JENKINS_TOKEN}" "${JENKINS_URL}$1" 2>/dev/null
}

{
    echo "# HELP homelab_jenkins_up Jenkins controller API reachable and authenticating (1=yes)."
    echo "# TYPE homelab_jenkins_up gauge"
    echo "# HELP homelab_jenkins_metrics_timestamp_seconds Unix time this file was last written."
    echo "# TYPE homelab_jenkins_metrics_timestamp_seconds gauge"
} > "$TMP"

COMPUTERS=$(api "/computer/api/json?tree=computer[displayName,offline,temporarilyOffline,numExecutors]")

if [ -z "$COMPUTERS" ]; then
    # Controller unreachable. Still write a fresh file so the timestamp stays
    # current and downstream alerts distinguish "Jenkins is down" from "this
    # script stopped running".
    emit "homelab_jenkins_up 0"
    emit "homelab_jenkins_metrics_timestamp_seconds $(date +%s)"
    mv -f "$TMP" "$OUT"; chmod 0644 "$OUT"; trap - EXIT
    exit 0
fi

emit "homelab_jenkins_up 1"

# Per-agent online state. The built-in controller node is excluded: it is
# always present and never the thing that blocks builds.
emit "# HELP homelab_jenkins_agent_online Jenkins agent online (1=online, 0=offline)."
emit "# TYPE homelab_jenkins_agent_online gauge"
echo "$COMPUTERS" | jq -r '
  .computer[]
  | select(.displayName != "Built-In Node" and .displayName != "master")
  | "homelab_jenkins_agent_online{agent=\"\(.displayName)\"} \(if .offline then 0 else 1 end)"
' >> "$TMP"

ONLINE=$(echo "$COMPUTERS" | jq '[.computer[] | select(.displayName != "Built-In Node" and .displayName != "master") | select(.offline | not)] | length')
TOTAL=$(echo "$COMPUTERS" | jq '[.computer[] | select(.displayName != "Built-In Node" and .displayName != "master")] | length')
emit "# HELP homelab_jenkins_agents_online_total Number of build agents currently online."
emit "# TYPE homelab_jenkins_agents_online_total gauge"
emit "homelab_jenkins_agents_online_total ${ONLINE:-0}"
emit "# HELP homelab_jenkins_agents_total Number of build agents configured."
emit "# TYPE homelab_jenkins_agents_total gauge"
emit "homelab_jenkins_agents_total ${TOTAL:-0}"

# Build queue. A healthy queue drains in seconds; a wedged executor turns this
# into an unbounded backlog (655 builds over 27h on 2026-09-14).
QUEUE=$(api "/queue/api/json?tree=items[inQueueSince]")
QLEN=$(echo "${QUEUE:-}" | jq '[.items[]?] | length' 2>/dev/null)
emit "# HELP homelab_jenkins_queue_length Number of items in the Jenkins build queue."
emit "# TYPE homelab_jenkins_queue_length gauge"
emit "homelab_jenkins_queue_length ${QLEN:-0}"

NOW_MS=$(($(date +%s) * 1000))
QAGE=$(echo "${QUEUE:-}" | jq --argjson now "$NOW_MS" '
  [.items[]?.inQueueSince] | if length == 0 then 0 else (($now - min) / 1000 | floor) end' 2>/dev/null)
emit "# HELP homelab_jenkins_queue_oldest_seconds Age of the oldest queued item."
emit "# TYPE homelab_jenkins_queue_oldest_seconds gauge"
emit "homelab_jenkins_queue_oldest_seconds ${QAGE:-0}"

# Longest currently-running build. Catches the executor-holding wedge: on
# 2026-09-14 homelab-updates-scheduled sat "building" for 32 hours holding one of
# jenkins-node-1's four executors, which is what let the queue explode.
BUILDING=$(api "/api/json?tree=jobs[name,lastBuild[building,timestamp]]")
LONGEST=$(echo "${BUILDING:-}" | jq --argjson now "$NOW_MS" '
  [.jobs[]? | select(.lastBuild?.building == true) | (($now - .lastBuild.timestamp) / 1000 | floor)]
  | if length == 0 then 0 else max end' 2>/dev/null)
emit "# HELP homelab_jenkins_longest_running_build_seconds Duration of the longest currently-running build."
emit "# TYPE homelab_jenkins_longest_running_build_seconds gauge"
emit "homelab_jenkins_longest_running_build_seconds ${LONGEST:-0}"

emit "homelab_jenkins_metrics_timestamp_seconds $(date +%s)"

mv -f "$TMP" "$OUT"
chmod 0644 "$OUT"
trap - EXIT
