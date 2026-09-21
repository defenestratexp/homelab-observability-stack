// Cloudflare Worker — bridges external webhook senders (Healthchecks.io,
// future external monitors, etc.) to our internal ntfy server. Lets us
// keep Cloudflare Bot Fight Mode enabled zone-wide on example.com,
// because Workers run on CF infrastructure and aren't subject to BFM.
//
// Two secrets in the account's Secrets Store, bound to this Worker via
// Settings → Variables and Secrets → Add binding → Secrets Store. The
// secrets themselves are named BRIDGE_SECRET and NTFY_TOKEN; the binding
// variable names (the env.X accessors) are homelab_bridge_secret and
// homelab_ntfy_token because Cloudflare won't let a binding shadow a Secrets
// Store entry name.
//
//   secret BRIDGE_SECRET / binding homelab_bridge_secret
//     → what external callers must send as Authorization bearer.
//       This is the public-facing credential.
//
//   secret NTFY_TOKEN / binding homelab_ntfy_token
//     → the real ntfy bearer token. Use a least-privilege user
//       (e.g. hc-publisher: write-only on the monitoring topic) so a
//       leaked Worker can't publish anywhere inappropriate.
//
// Note: Secrets Store bindings expose each value as an object with an
// async .get() method, not a string. If you ever switch to inline encrypted
// variables instead, drop the awaits below — env.X becomes the string
// directly and `await string.get()` will throw.
//
// Caller endpoint shape — supports both ntfy publish styles:
//
//   A. Path-based (simple): POST  https://<worker-url>/<topic>
//      Body: plain text message, optional Title / Priority / Tags headers
//
//   B. JSON publish API:    POST  https://<worker-url>/
//      Body: {"topic":"...", "message":"...", "title":"...", ...}
//      Used by integrations like Healthchecks.io that don't put the topic
//      in the URL.
//
//   Both styles send Authorization: Bearer <BRIDGE_SECRET>.

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') {
      return new Response('Method not allowed', { status: 405 });
    }

    // Resolve secrets. With Secrets Store bindings each binding is an object
    // with an async .get(); see the header comment if you ever switch to
    // inline encrypted variables instead.
    //
    // Binding variable names (env.X) must NOT collide with names already
    // used in the account's Secrets Store, so we use homelab_*-prefixed names
    // for the bindings and keep the Secrets Store entries themselves named
    // BRIDGE_SECRET / NTFY_TOKEN.
    const bridgeSecret = await env.homelab_bridge_secret.get();
    const ntfyToken = await env.homelab_ntfy_token.get();

    // 1. Validate the inbound bridge secret. This is the only auth boundary
    //    on the public side; anyone with this bearer can publish through
    //    the Worker (subject to whatever NTFY_TOKEN itself is allowed to do).
    const auth = request.headers.get('authorization') || '';
    if (auth !== `Bearer ${bridgeSecret}`) {
      return new Response('Unauthorized', { status: 401 });
    }

    // 2. Decide which publish style we're handling. The JSON publish API
    //    puts everything in the body and posts to root; path-based puts the
    //    topic in the URL with a plain-text body. Validate the topic in
    //    either case so a malicious caller can't smuggle weird values.
    const url = new URL(request.url);
    const pathTopic = url.pathname.replace(/^\/+/, '').split('/')[0];
    const contentType = request.headers.get('content-type') || '';
    const isJsonPublish = contentType.includes('application/json') && pathTopic === '';

    let ntfyUrl, ntfyBody, ntfyContentType;
    if (isJsonPublish) {
      const text = await request.text();
      let parsed;
      try {
        parsed = JSON.parse(text);
      } catch (e) {
        return new Response('Bad JSON body', { status: 400 });
      }
      if (!parsed.topic || !/^[A-Za-z0-9_\-.]+$/.test(parsed.topic)) {
        return new Response('Bad or missing topic in JSON body', { status: 400 });
      }
      ntfyUrl = 'https://ntfy.example.com/';
      ntfyBody = text;
      ntfyContentType = 'application/json';
    } else {
      if (!pathTopic || !/^[A-Za-z0-9_\-.]+$/.test(pathTopic)) {
        return new Response('Bad topic', { status: 400 });
      }
      ntfyUrl = `https://ntfy.example.com/${pathTopic}`;
      ntfyBody = await request.arrayBuffer();
      ntfyContentType = contentType || 'text/plain';
    }

    // 3. Build the forwarded request. Replace the inbound bearer with the
    //    real ntfy token. For path-based publishes, pass through the ntfy
    //    message headers (title/priority/etc); for JSON publishes those
    //    fields are already in the body.
    const fwd = new Headers();
    fwd.set('Authorization', `Bearer ${ntfyToken}`);
    fwd.set('content-type', ntfyContentType);
    if (!isJsonPublish) {
      for (const h of ['title', 'priority', 'tags', 'click', 'icon']) {
        const v = request.headers.get(h);
        if (v) fwd.set(h, v);
      }
    }
    const cfIp = request.headers.get('cf-connecting-ip');
    if (cfIp) fwd.set('x-forwarded-for', cfIp);

    // 4. Forward to ntfy and proxy back its response verbatim. We don't
    //    transform the body so callers see the actual ntfy success/error
    //    JSON, which makes integration debugging easier.
    const resp = await fetch(ntfyUrl, {
      method: 'POST',
      headers: fwd,
      body: ntfyBody,
    });
    return new Response(resp.body, {
      status: resp.status,
      headers: { 'content-type': resp.headers.get('content-type') || 'application/json' },
    });
  },
};
