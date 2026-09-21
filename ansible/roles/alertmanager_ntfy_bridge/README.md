# alertmanager_ntfy_bridge

Deploys [alexbakker/alertmanager-ntfy](https://github.com/alexbakker/alertmanager-ntfy) into the `monitoring` namespace on k3s-main. The bridge translates Alertmanager's webhook JSON into ntfy publishes against `ntfy.example.com`. Phase 1 step 8 of the homelab monitoring rollout.

## What it does

1. Fetches the ntfy admin token from AWS Secrets Manager (`homelab/ntfy/admin-token`).
2. Renders the bridge config (with token inline) as a k8s Secret.
3. Applies Deployment + Service into the `monitoring` namespace.
4. Waits for the rollout to complete.

## Topic routing

The bridge config uses a gval expression to read each alert's `topic` label and publish to that ntfy topic:

```yaml
topic: |
  labels.topic
```

gval as used by alertmanager-ntfy cannot default a missing map key, so the `additionalAlertRelabelConfigs` in `ansible/files/kube-prometheus-stack-values.yaml` guarantee every alert carries `topic` (falling back to `monitoring`) and `severity` before it reaches Alertmanager.

PrometheusRule alert definitions set the topic via labels:

```yaml
labels:
  topic: host       # → ntfy `host` topic
  severity: warning
```

Topics used by the rules in this repo: `host`, `synthetic`, `cluster` (chart-bundled alerts), `monitoring` (Jenkins alerts and the default fallback).

## Message layout

Notifications use a Nagios-style layout: the title is `[CRIT]|[WARN]|[OK] <host> · <service>` and the body is a fixed `HOST / SERVICE / STATE / CHECK` block followed by the alert description. See `templates/secret.yaml.j2`.

The bridge reads its config only at startup, so the role runs `kubectl rollout restart` whenever the rendered Secret changes.

## Severity mapping

| Alert label `severity` | ntfy priority |
|---|---|
| `critical` | high |
| `warning` | default |
| anything else / unset | low |

## Why a Secret (not a ConfigMap)

The bridge config holds the ntfy bearer token. Putting the whole config in a Secret keeps the token out of `kubectl get cm` output. Bridge supports split configs for separating token from non-sensitive config; we'll switch to that pattern if we ever want to track the non-sensitive bits in version control as a ConfigMap.

## Variables

See `defaults/main.yml`.

## Target

Runs against `k3s-main` (the host with the k3s control plane), uses local k3s kubeconfig.
