# prometheus_stack

Deploys [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) on k3s-main via helm. Phase 1 of the homelab monitoring rollout.

## What it does

1. Verifies k3s is running on the target.
2. Installs helm if missing.
3. Stages the helm values file from the controller to the target.
4. Adds the `prometheus-community` helm repo and updates.
5. Applies the `monitoring` namespace.
6. `helm upgrade --install` the chart with the staged values.
7. Waits for Prometheus and Alertmanager pods to reach Ready.
8. Reports pod status.

## Variables

See `defaults/main.yml`. Key knobs:

- `prometheus_stack_values_file` — path on the controller to the helm values yaml. Defaults to `ansible/files/kube-prometheus-stack-values.yaml`. Override with `-e prometheus_stack_values_file=...`.
- `prometheus_stack_chart_version` — pin once we have a known-good version; empty = latest.
- `prometheus_stack_helm_timeout` — `helm install --wait` timeout, default `10m`.

## Target

Runs against `k3s-main` (the host with the k3s control plane). Uses the local k3s kubeconfig at `/etc/rancher/k3s/k3s.yaml`.

## Why this design (not GitOps yet)

For Phase 1 everything is imperative-via-Ansible, matching how the rest of the homelab is deployed. Once the round-trip is proven, future iterations can move to a GitOps controller (Argo, Flux) — the helm values and CRDs are plain files, so that handoff is straightforward.
