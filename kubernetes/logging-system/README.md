# Centralized Logging System

Centralized log aggregation using Loki, Vector, and Grafana deployed on the k3s-main cluster.

## Architecture

```
┌─────────────────┐                         ┌─────────────────┐
│ k3s-main K8s    │                         │ k3s-util K8s    │
│     Vector      │                         │     Vector      │
│   (DaemonSet)   │                         │   (DaemonSet)   │
└────────┬────────┘                         └────────┬────────┘
         │                                           │
         ▼                                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Loki (k3s-main:31100)                        │
│                    30-day retention                             │
│                    NFS storage on nas                           │
└─────────────────────────────────────────────────────────────────┘
         ▲                       ▲
         │                       │
┌────────┴────────┐     ┌────────┴────────────┐
│  Syslog (UDP)   │     │ Docker (k3s-util)   │
│  Port 31514     │     │ nginx-proxy, coredns│
│  All hosts      │     │                     │
└─────────────────┘     └─────────────────────┘
```

## Components

### Loki
- **Purpose**: Log aggregation and storage
- **Storage**: NFS PV on nas (`/mnt/archive/loki`, see `loki/pv.yaml`)
- **Retention**: 30 days
- **Ports**:
  - ClusterIP 3100 (internal)
  - NodePort 31100 (external collectors)

### Vector
Deployed as DaemonSet on each cluster to collect logs.

| Cluster | Sources | Labels |
|---------|---------|--------|
| k3s-main | K8s pods, syslog (UDP 31514) | `cluster=k3s-main` or `cluster=network` |
| k3s-util | K8s pods | `cluster=k3s-util-k8s` (manifests for that cluster are not included in this repo) |

Standalone Vector container on k3s-util collects Docker logs (nginx-proxy, coredns) with `cluster=k3s-util`.

### Grafana
- **URL**: http://logs.example.internal (proxied via nginx on k3s-util)
- **Direct**: http://192.0.2.68:30085
- **Auth**: admin / (from AWS Secrets Manager `homelab/grafana/admin-password`, fetched by an init container; needs the `aws-credentials` Secret — see `grafana/aws-credentials-secret.yaml.example`)

## Dashboards

| Dashboard | Purpose | Key Features |
|-----------|---------|--------------|
| **Syslog Overview** | All syslog hosts at a glance | Logs by host, severity, top apps |
| **Host Explorer** | Per-host drill-down | Dropdown selector, SSH/sudo/errors |
| **Security / Auth** | Authentication events | SSH sessions, sudo, failed attempts |
| **Guacamole / Remote Host** | Remote access server | SSH, Docker, UFW blocks |
| **Nginx / Reverse Proxy** | HTTP access logs | Status codes, client IPs, methods |
| **CoreDNS** | DNS query logs | Query types, response codes, clients |
| **Jenkins** | CI/CD logs | Build logs, errors, warnings |
| **Graphics Suite** | kroki-system namespace | Kroki, PiGallery, Penpot, Draw.io/Excalidraw logs |
| **Eternal Forge** | eternal-system namespace | App + Postgres logs |
| **External Secrets Operator** | ESO controller logs | Sync events, errors |

## Syslog Hosts

Hosts configured to forward syslog to Vector (via rsyslog):

- media-worker, laptop, nas, jenkins-node-1, jenkins-node-2
- k3s-main, remote-host, stream-host, console-host
- k3s-util, workstation, notes-host

Configure additional hosts with the `ansible/playbooks/configure_rsyslog_forwarding.yml` playbook.

## Log Labels

### Syslog Logs
```
source_type="syslog"
cluster="network"
```
JSON fields (use `| json` to parse):
- `hostname` - originating host
- `appname` - application name (sshd, sudo, cron, etc.)
- `severity` - info, warning, error, etc.
- `facility` - kern, auth, daemon, etc.
- `message` - log message content

### Kubernetes Logs
```
source_type="kubernetes"
cluster="k3s-main" | "k3s-util-k8s"
namespace="..."
pod="..."
container="..."
```

## Common LogQL Queries

### All logs from a specific host
```logql
{source_type="syslog"} |= "\"hostname\":\"k3s-main\"" | json
```

### SSH authentication events
```logql
{source_type="syslog"} | json | appname="sshd"
```

### Failed authentication attempts
```logql
{source_type="syslog"} | json | appname="sshd" |~ "(?i)(fail|invalid|denied)"
```

### Sudo commands
```logql
{source_type="syslog"} | json | appname="sudo"
```

### UFW blocked connections
```logql
{source_type="syslog"} | json | appname="kernel" |= "UFW BLOCK"
```

### Kubernetes pod logs
```logql
{source_type="kubernetes", cluster="k3s-main", namespace="monitoring"}
```

### Count logs by host (last hour)
```logql
sum by (hostname) (count_over_time({source_type="syslog"} | json [1h]))
```

## File Structure

```
logging-system/
├── namespace.yaml
├── loki/
│   ├── configmap.yaml      # Loki configuration
│   ├── statefulset.yaml    # StatefulSet
│   ├── pv.yaml / pvc.yaml  # NFS storage
│   └── service.yaml        # ClusterIP + NodePort
├── vector/
│   ├── configmap.yaml      # Vector pipeline config
│   ├── daemonset.yaml      # DaemonSet for log collection
│   ├── service.yaml        # syslog UDP NodePort 31514
│   └── serviceaccount.yaml, clusterrole*.yaml  # RBAC for K8s API access
└── grafana/
    ├── configmap.yaml      # datasource + grafana.ini settings
    ├── aws-credentials-secret.yaml.example
    ├── deployment.yaml     # Deployment with init container
    ├── pvc.yaml            # Persistent storage
    ├── service.yaml        # NodePort 30085
    ├── dashboard-provider.yaml
    └── dashboard-*.yaml    # Dashboard definitions
```

## Operations

### Restart Grafana (after dashboard changes)
```bash
kubectl rollout restart deployment/grafana -n logging-system
```

### Check Vector logs
```bash
kubectl logs -n logging-system -l app=vector --tail=50
```

### Query Loki directly
```bash
curl -s "http://192.0.2.68:31100/loki/api/v1/query" \
  --data-urlencode 'query={source_type="syslog"} | json | hostname="k3s-main"' \
  --data-urlencode 'limit=10' | jq .
```

### Add syslog forwarding to a new host
Run the Ansible playbook via Jenkins:
- Playbook: `configure_rsyslog_forwarding.yml`
- Limit: target hostname

## Troubleshooting

### No logs appearing for a host
1. Check rsyslog is forwarding: `logger "test message" && sleep 2 && grep test /var/log/syslog`
2. Verify UDP connectivity: `nc -u 192.0.2.68 31514` (type message, check Loki)
3. Check Vector logs for parsing errors

### Dashboard shows "No data"
1. Verify time range is appropriate
2. Check LogQL query syntax in panel edit mode
3. For log panels, use line filters before `| json` for stream selection
4. For metric panels, `| json | field="value"` works fine

### Template variable errors
Use static custom type for hostname variables instead of `label_values()` queries on JSON-parsed fields.
