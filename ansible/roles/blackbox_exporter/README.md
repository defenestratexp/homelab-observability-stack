# blackbox_exporter

Deploys [prometheus-blackbox-exporter](https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus-blackbox-exporter) into the `monitoring` namespace on k3s-main. Phase 2b of the homelab monitoring rollout.

## What it does

1. Verifies k3s is running.
2. Stages the helm values file on the target.
3. `helm upgrade --install` the chart with our values (`fullnameOverride: blackbox-exporter`).
4. Waits for the pod to be Ready.

## Modules configured

- `http_2xx` — standard HTTP probe expecting 2xx response.
- `http_2xx_no_tls_verify` — same but skips cert chain validation. Use for internal `*.home.example.com` endpoints if the pod's CA store doesn't yet trust LE.
- `tcp_connect` — raw TCP probe (Postgres on db-host, NFS/rpcbind on nas).

## Probes

Probe CRD definitions live in `ansible/files/prometheus-rules/probes.yaml` and are applied by the `prometheus_rules` role. Each Probe references the blackbox-exporter service at `blackbox-exporter.monitoring:9115` (the chart's `fullnameOverride`).

## Target

Runs against k3s-main; uses the local k3s kubeconfig.
