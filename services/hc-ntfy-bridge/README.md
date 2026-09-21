# hc-ntfy-bridge

A Cloudflare Worker that forwards external webhook senders (Healthchecks.io, future external monitors) to our internal ntfy server. Bypasses Cloudflare Bot Fight Mode — Workers run on CF's own infrastructure and aren't subject to BFM, which means we can keep BFM enabled zone-wide on `example.com` *and* still let datacenter-hosted services publish notifications.

## Why this exists

Healthchecks.io's outbound IPs (Hetzner Cloud) get blocked by Cloudflare's Bot Fight Mode. Custom WAF rules can't fully `Skip` BFM on the Free plan; per-hostname BFM toggles need a Pro plan Configuration Rule. The Worker sidesteps that constraint at zero cost.

## Architecture

```
HC.io (or any external sender)
   │  POST https://<worker>.workers.dev/<topic>
   │  Authorization: Bearer <BRIDGE_SECRET>
   ▼
Cloudflare Worker (this repo: worker.js)
   │  validates BRIDGE_SECRET
   │  rewrites Authorization to Bearer <NTFY_TOKEN>
   │  passes through Title / Priority / Tags / Click / Icon
   ▼
https://ntfy.example.com/<topic>  → self-hosted ntfy
```

## Deployment

The worker is deployed via the Cloudflare dashboard, not Jenkins (yet — there's no `wrangler` integration in any of our containerized envs). To redeploy:

1. Open the Worker in the Cloudflare dashboard
2. **Edit code** → paste the contents of `worker.js`
3. **Deploy**

## Required secrets

Stored in the **Cloudflare Secrets Store** (account-level), then bound to the Worker via Settings → Variables and Secrets → **Add binding → Secrets Store**.

| Secrets Store entry | Worker binding variable name | Value | Source of truth |
|---------------------|------------------------------|-------|-----------------|
| `BRIDGE_SECRET` | `homelab_bridge_secret` | A random alphanumeric (32–64 chars) | Generated once; share with each external service that publishes through the bridge |
| `NTFY_TOKEN` | `homelab_ntfy_token` | The least-privilege ntfy token for the bridge to publish on the caller's behalf | AWS Secrets Manager: `homelab/ntfy/hc-publisher-token` |

The binding variable names use `homelab_*` prefixes because Cloudflare doesn't let a binding's variable name match an existing Secrets Store entry name in the same account.

`NTFY_TOKEN` should be a narrow user — the `hc-publisher` user has write-only access to the `monitoring` topic, so even a fully compromised Worker can only spam that topic.

## Wiring an external service to it

Example: HC.io's ntfy integration form
- **Server URL**: `https://<worker-name>.<account>.workers.dev`
- **Topic**: `monitoring` (or whatever you pass in the URL path)
- **Bearer token**: the `BRIDGE_SECRET` value

The Worker rewrites the Bearer to the real ntfy token before forwarding, so external services never see `NTFY_TOKEN` directly.

## Adding more external publishers later

Same `BRIDGE_SECRET` works for everyone, OR rotate `BRIDGE_SECRET` per service for blast-radius isolation. If you go multi-secret, the Worker would need a small rewrite to accept any of N valid bearers — easy to add when the second integration shows up.

## Future: wrangler-based deploys

When the third or fourth Worker arrives, add a containerised `wrangler` environment so Workers deploy from CI instead of being pasted into the dashboard.
