# prometheus_rules

Applies all PrometheusRule CRD yaml files from `ansible/files/prometheus-rules/` into the `monitoring` namespace on k3s-main. The Prometheus Operator picks them up and Prometheus reloads automatically.

## What's here

The CRDs live at `ansible/files/prometheus-rules/`:

```
files/prometheus-rules/
├── host.yaml                       # node_exporter alerts (HostDown, DiskCritical, NFS, inodes...) → topic: host
├── synthetic.yaml                  # blackbox probe alerts (EndpointDown/Slow, TLS expiry)         → topic: synthetic
├── jenkins.yaml                    # Jenkins controller/agent/queue alerts (textfile metrics)      → topic: monitoring
├── probes.yaml                     # Probe CRDs: public HTTPS, internal HTTPS, raw TCP targets
└── alertmanager-web-nodeport.yaml  # NodePort Service exposing the Alertmanager UI
```

Everything in the directory is applied with a single `kubectl apply -f`, so non-rule manifests (Probes, the NodePort Service) ride along with the rules.

## How alerts route to ntfy topics

Each alert sets a `topic: <name>` label. The alertmanager-ntfy bridge reads that label via gval expression and publishes to the matching ntfy topic. See `roles/alertmanager_ntfy_bridge/templates/secret.yaml.j2`.

Every host alert is labeled `topic: host`; synthetics get `topic: synthetic`, etc. Default fallback is `topic: monitoring`.

## Why a dedicated role

Rules will multiply. Keeping them separate from the prometheus_stack helm release lets us iterate on alert tuning without bumping the chart.

The `*SelectorNilUsesHelmValues: false` setting in the chart values means Prometheus picks up rules from any namespace without needing a release label, so we can land new rules without re-running prometheus_stack.

## Target

Runs against k3s-main; uses the local k3s kubeconfig.
