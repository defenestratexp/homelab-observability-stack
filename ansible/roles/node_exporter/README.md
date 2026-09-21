# node_exporter

Installs Prometheus [node_exporter](https://github.com/prometheus/node_exporter) as a systemd service, listening on `:9100`. Phase 2-broadening role for the homelab monitoring rollout.

## What it does

1. Detects init system. Fails on non-systemd hosts (SysV support can be added alongside if/when we apply this to MX Linux hosts).
2. Creates the `node_exporter` system user/group.
3. Downloads + installs the binary at the version pinned in `defaults/main.yml`.
4. Drops a hardened systemd unit (`NoNewPrivileges`, `ProtectHome`, `ProtectSystem=strict`).
5. Enables and starts the service.
6. Probes `/metrics` to verify it's actually serving.

## Variables

See `defaults/main.yml`. Key knobs:

- `node_exporter_version` — pinned. Bump deliberately; download URL is built from this.
- `node_exporter_listen_address` — defaults to `0.0.0.0:9100`. Lock to a specific interface if a host has multiple NICs and you only want it scraped on one.
- `node_exporter_extra_args` — additional `--collector.*` flags if you need to enable/disable specific collectors.

## Target

Apply to the `monitored_hosts` inventory group. Phase 1 starts with `nas` only; Phase 2 extends to the rest of the LAN.

## Why pin a version

Auto-pulling latest would silently change the metric set on each rerun (collectors are added/deprecated between minor versions), which would invalidate alert rules and dashboards without warning. Pin and bump deliberately when we want the new metrics.
