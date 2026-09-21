# monitoring

Namespace for the Prometheus + Alertmanager stack on `k3s-main`. The stack itself is deployed by the `prometheus_stack` Ansible role ([../../ansible/roles/prometheus_stack](../../ansible/roles/prometheus_stack/README.md)); this directory only holds the namespace manifest.

## What's here

```
monitoring/
├── namespace.yaml   # the monitoring namespace
└── README.md        # this file
```

**Note on helm values location:** `kube-prometheus-stack-values.yaml` lives in `ansible/files/` next to the playbooks, so the Jenkins job that runs the deploy role finds it with a single checkout. Runtime CRDs (PrometheusRule, Probe) live in `ansible/files/prometheus-rules/` and are applied by the `prometheus_rules` role.

Planned additions:

| Phase | Adds |
|---|---|
| 1 | bare stack, host alert rules |
| 2 | PrometheusRule CRDs for host/synthetic alerts, Probe CRDs for blackbox checks (done — see `ansible/files/prometheus-rules/`) |
| 3 | cluster-level rules |
| 4 | ServiceMonitors — postgres-exporter, jenkins, icecast |

## Why these helm values

- `grafana.enabled: false` — keeps the existing standalone Grafana (see `../logging-system/grafana/`) instead of running two Grafanas.
- `kubeControllerManager/Scheduler/Etcd/Proxy: enabled: false` — k3s ships those differently than upstream k8s; scraping them errors out. Kubelet + kube-state-metrics covers everything that matters.
- `serviceMonitorSelectorNilUsesHelmValues: false` (and siblings) — Prometheus picks up any matching CRD across all namespaces, not just ones with the helm release label.
- 30d retention, 10Gi local-path PVC, conservative resource limits — sized for homelab scale.

## Deploying

Via Jenkins (the canonical path):

1. Trigger the Ansible Jenkins job (`ansible/Jenkinsfile`) with `PLAYBOOK=playbooks/deploy_prometheus_stack.yml`.
2. The pipeline clones this repo and runs the `prometheus_stack` role, which `helm upgrade --install`s the chart against `k3s-main` using `ansible/files/kube-prometheus-stack-values.yaml`.
