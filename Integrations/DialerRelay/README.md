# Search protected Dialer relay

This server package routes the built-in Dialer's media through the user's saved proxy without public STUN services. Signaling separately uses WebKit's mandatory proxy configuration for the same saved proxy. The native TURN tunnel carries media relay traffic. This package does not enable calling from private or onion tabs.

## Native contract

Send `POST https://sip.investigate.agency/search-dialer/turn`, with the existing seat's HTTP Basic credentials and an empty body or `{}`. Use verified TLS through the saved proxy, refuse redirects, and bound responses to 32 KiB. The server accepts only the configured seat, currently `1001`; its existing password is loaded from the owned FreeSWITCH seat file. Never export that password to websites or logs.

The JSON response is:

```json
{
  "iceServers": [{
    "urls": ["turns:sip.investigate.agency:5349?transport=tcp"],
    "username": "<expiry>:1001:<random nonce>",
    "credential": "<expiring HMAC credential>"
  }],
  "expiresAt": 2000003600,
  "ttl": 3600
}
```

The native bridge validates the configured WSS hostname, issuer hostname, TURN hostname, TLS URL, expiry and port. It connects its ephemeral loopback TCP listener to the fixed TURN TLS endpoint through the saved HTTP, HTTPS or SOCKS5 proxy, with hostname/certificate verification. Only the TURN URL is rewritten for the bundled page to `turn:127.0.0.1:<ephemeral port>?transport=tcp`. Set `iceTransportPolicy: "relay"` and supply only this TURN entry. No STUN server, direct media candidate, direct fallback or certificate exception is allowed. Stop local tunnels and the call when the protected route or its configuration changes.

Fetch fresh credentials before a new call when fewer than 60 seconds remain, and when idle after expiry. Do not reboot an active call merely to refresh its credential. In coturn 4.6.1, REST expiry is checked during initial key lookup (`userdb.c`, `get_user_key`), while authenticated sessions retain their HMAC key for refresh (`ns_turn_server.c`, `check_stun_auth`). A new connection or ICE allocation after expiry needs fresh credentials. Reconnection must fail closed if credentials cannot be renewed.

Issuer failures contain only `{"error":"<tag>"}`: `bad_request` (400), `authentication_required` (401), `not_found` (404), `method_not_allowed` (405), `request_too_large` (413), or `rate_limited` (429). Nginx can also return generic 429/413/502/503 responses; clients must handle status codes without displaying HTML. HTTP headers, request bodies and responses are never logged. The payload is protected by authenticated TLS; it has no separate application signature.

`GET https://sip.investigate.agency/search-dialer/route-check` returns only `{"ip":"<connection source IP>"}` with `Cache-Control: no-store`. It requires no credentials and performs no third-party lookup. Access logs remain disabled. It is intended for checking the saved proxy route without a public geolocation service; it reports no country or timezone.

## Deployment boundaries

Use the existing owned VPS and its valid `sip.investigate.agency` certificate. Port 443's existing nginx sites remain intact; add the HTTPS virtual host in `nginx-search-dialer.conf` alongside the existing port-80 ACME host. The issuer listens only on a group-restricted Unix socket and receives exactly the seat XML and TURN secret through systemd `LoadCredential`. It has no Internet socket capability. Credentials and the private generated coturn config belong only on the server, with root-only or root/service-group read access.

Create a random URL-safe TURN secret (at least 32 random bytes), store it at `/etc/search-dialer-relay/turn-secret` mode 0600, and generate the private coturn config using `render_config.py --secret-file ... --output ...`. It refuses to overwrite an existing file. The rendered config enables only TLS client connections on 5349, denies standalone STUN, and permits UDP relay allocations only to the owned FreeSWITCH IPv4 address. Both IP families otherwise have deny-all peer rules. Four allocations per ephemeral username and twenty total bound resource use; network bandwidth is capped. No arbitrary client caller ID or trunk configuration is changed.

Before installing coturn, mask its distribution service so installation cannot expose default listeners. Use only `search-dialer-turn.service` with the generated config. Give `turnserver` read access to only this copied certificate/key pair. Install `renew-certificate.sh` as a Certbot deploy hook, preserving existing hooks; it refreshes only this hostname's copies and restarts only the TURN service. The shared secret remains server-side; the app receives only expiring credentials. Seat password rotation requires restarting the issuer to reload its systemd credential copy.

Back up every changed path and its metadata in a root-only dated directory. Validate `nginx -t` before a reload; never restart FreeSWITCH or unrelated trunks. Open only TCP 5349 in UFW. Media relay UDP ports 49160–49200 remain externally closed: the sole peer is FreeSWITCH on the same host. Verify its local RTP path before claiming audio works. Additional egress filtering can constrain the TURN service's UDP peers to this host's FreeSWITCH RTP port range.

## Offline validation

```sh
python3 -m unittest discover -s Integrations/DialerRelay/tests -v
```

Tests use synthetic credentials, Unix sockets and in-memory HMAC checks. They place no calls and access no account credentials. Deployment checks should verify TLS, unauthenticated refusal, method/body/rate limits, an authenticated TURN allocation, denied off-host peers, and cleanup. Real audio proof requires the separate owned `9196` echo test through the saved proxy; no carrier call is necessary.

Primary references: [coturn 4.6.1 configuration](https://github.com/coturn/coturn/blob/4.6.1/examples/etc/turnserver.conf), [TURN REST/peer rules](https://github.com/coturn/coturn/blob/4.6.1/README.turnserver), [WebRTC relay-only ICE](https://w3c.github.io/webrtc-pc/#dom-rtcicetransportpolicy-relay), [TURN transports](https://www.rfc-editor.org/rfc/rfc8656.html#section-3.1).
