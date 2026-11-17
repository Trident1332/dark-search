# Owned Numero lines through FreeSWITCH

This package supports server-owned US/Canada caller-ID allowlists and an
optional account-specific selector. In selector mode, each line uses its own
verified Numero account, SIP gateway, and private API session. The browser
supplies a line ID and destination; account credentials remain on the server.
The generator makes no network requests or deployment changes. Python 3.10+
and the standard library are required; the optional gate uses FreeSWITCH's
existing Lua/JSON support plus BusyBox `nc`, `sed`, and `timeout` in the container.

## Browser/server contract

Search sends one of these SIP Request-URI user parts to its configured
FreeSWITCH domain:

- `numero-us-<E164digits>` selects the allowlisted US line.
- `numero-ca-<E164digits>` selects the allowlisted Canada line.

The destination contains 6–15 ASCII digits, starts with 1–9, and has no `+`.
A caller ID, gateway name, account identity, or token is never accepted from
the browser. Both routes require `sip_authorized=true` and the authorized seat.
An unconditional final rejection catches unknown/malformed `numero-*` requests,
including unauthorized seats. These prefixes cannot fall through to an old
numeric-only route or silently select its default line. Unrelated numeric and
UK/Telicall routes are unchanged by this fragment.

## Private line configuration and modes

Keep `lines.json` outside the checkout, root-owned with mode `0600`, in a
root-owned `0700` directory. Do not put passwords or API headers in it.
`lines` contains exactly two distinct administrator-verified canonical `+1`
NANP DIDs. Number syntax alone does not establish ownership or country.

```python
config = {
    "gateway": "numero",
    "authorized_seat": "1001",
    "lines": {"us": owned_us_e164, "ca": owned_canadian_e164},
    "line_gateways": {"us": "numero", "ca": "numero_ca"},
}
```

The optional `line_gateways` key opts into the account-specific selector.
Only `us=numero` and `ca=numero_ca` are accepted. A missing line mapping emits
a terminal temporary-failure route for that line; it never falls back to the
other account. Unknown or cross-account mappings reject the configuration.
`validate(config)` returns an independent canonical dictionary and
`generate(config)` returns XML. `load_config(Path(...))` also rejects duplicate
JSON keys and oversized input without echoing configured values in diagnostics.

Without `line_gateways`, the generator preserves its original direct-bridge
behavior: both line IDs use `gateway`, the configured DID supplies bare digits
in caller-ID fields, and `caller-id-in-from=true` is required. This legacy mode
performs no provider API selection. It cannot establish that a provider has
selected the requested outgoing number or that both DIDs belong to one account.
Use explicit account mapping when the lines belong to different logins.

## Account-specific selector

`number_selector.py` listens only on `127.0.0.1:18082`. The Lua gate and service
share a local bearer stored in a root-owned `0600` header configuration file;
it is never placed in process arguments or FreeSWITCH API command events.
The existing `.wgetrc` filename is retained for compatibility, but no wget
options are used. BusyBox `sed` streams the header directly from that private
file into `nc` stdin. A fixed HTTP/1.0 POST goes only to loopback port 18082;
there are no redirects, proxy environment use, secret command arguments,
environment variables, or temporary secret files. BusyBox `timeout -s KILL`
bounds the whole nc exchange. Lua requires a successful process exit, bounded
headers/body, one matching Content-Length, matching HTTP/JSON status, and valid
JSON. Truncation, trailing bytes, chunked encoding, redirects, or malformed
responses fail closed. GNU wget options must not be assumed on the container's
BusyBox wget; offline mocks alone do not establish installed CLI compatibility.
The fixed server paths are:

| Line | Gateway XML | API session |
| --- | --- | --- |
| US | `/root/telicall/fs/conf/sip_profiles/external/numero.xml` | `/root/search-numero/api-session.json` |
| Canada | `/root/telicall/fs/conf/sip_profiles/external/numero_ca.xml` | `/root/search-numero/accounts/ca/api-session.json` |

The selector reads `/root/search-numero/lines.json`. Session files and parent
directories must be root-owned, respectively `0600` and `0700`, with no symlink
or hardlink file aliases. Canada has no US-session fallback. Each session has
`schema_version=1`, `issued_utc`, `account_binding` (`gateway`, exact gateway
`username`, decimal `id_client`), `owned_lines`, and the six captured headers:
`language=english`, `app_Version`, `os`, `Access-Key`, `Security-Token`, and
`Id-Client`. Header values and account identity must match the binding.
`owned_lines` may contain both administrator-allowlisted DIDs for compatibility,
but its effective allowlist is limited to this account's explicitly mapped
line. An optional `provider_expires_utc` is honored; no arbitrary local token
expiry or automatic login is invented. Never commit these private files.

Before every provider operation, the service verifies a real active FreeSWITCH
UUID for authenticated seat `1001`, the exact line/destination prefix, and a
registered/UP matching gateway. It performs one verified-HTTPS GET of
`my-active-numbers-dial`, requires the requested DID to occur exactly once, and then POSTs only `new_number=<exact raw provider number>` to
`change-number`. A second GET must prove that exact line alone is selected and
private-number mode is off. The official outgoing-number model does not
use `voice_enabled`; absent, zero, or string values in that unmodeled field
do not replace the account ownership and accepted-selection checks. There are no redirects, login attempts, purchases,
blind retries, or arbitrary provider endpoints. Absent ownership or verification
fails before bridging; absent ownership fails before the POST.

Selection is serialized per provider account (`Id-Client`) and held until its
authenticated A-leg ends. An account already in use returns SIP 486; unavailable
sessions, gateways, or failed selection return 503. Independent accounts have
independent leases. A service-restart guard checks existing Numero channels,
and a bounded poll reaps ended calls; PBX unavailability does not release a
live lease. Local release requests cannot free an active call prematurely.

The provider's expired-session response (`response_code=-9999`) is classified
as `session_expired`. Failed selection writes only an allowlisted diagnostic
tag to the service journal; it never logs response bodies, credentials, account
identities or dialed numbers. An expired API session must be refreshed before
the route can be tested again, even if its SIP gateway remains registered.

After success, Lua bridges only through the line's fixed gateway. It sets the
From URI to the trusted gateway account, the display name and caller-ID fields
to the verified owned DID's bare digits, `sip_cid_type=none`, and PCMU on the
provider leg. It does not copy arbitrary custom headers. This follows the
observed app's account-URI/selected-display separation. Existing US gateway
`caller-id-in-from=true` may remain; selector mode explicitly overrides the
per-call URI/display and accepts one explicit boolean gateway setting. A new
Canada gateway can use `false`. Registration credentials and other trunks need
no changes merely to install the selector.

## Generate, review, and deploy

1. Run all offline tests and Lua syntax validation:

   ```sh
   python3 -m unittest discover -s Integrations/Numero/tests -v
   luac -p Integrations/Numero/numero_select.lua
   ```

   Lua bridge tests use an in-memory FreeSWITCH/HTTP fixture; they place no
   calls and make no provider requests. They do not replace a deployed check.

2. Generate a new private candidate and verify both mapped gateway XML files:

   ```sh
   python3 Integrations/Numero/generate_dialplan.py /private/path/lines.json \
     --line-gateway-xml us=/private/path/numero.xml \
     --line-gateway-xml ca=/private/path/numero_ca.xml \
     --output /private/path/20_search_numero_lines.xml
   ```

   Files use `0600`; existing output files are never overwritten. Omitting
   `--output` prints private caller-ID XML in legacy mode; avoid shared logs.
   Legacy deployments may use `--gateway-xml` to verify their single gateway.

3. **Before activating Canada**, verify the correct account's ownership and
   outgoing-list eligibility through its genuine profile response, create its
   separate private API session, and register only `numero_ca` with that
   account's approved saved SIP credential. Stop if verification or ownership
   is missing; do not reuse the US login or rotate it as a fallback.

4. With no active calls, back up only the affected private files/metadata in a
   dated root-owned `0700` directory. Install Python modules and the included
   selector service under `/usr/local/lib/search-numero/`, then install
   `numero_select.lua` in the container's bind-mounted scripts directory.
   Create the root-owned `0600` shared header config at host
   `/root/telicall/fs/scripts/search-numero-selector.wgetrc` (container path
   `/usr/share/freeswitch/scripts/search-numero-selector.wgetrc`) with exactly
   one `header = Authorization: Bearer <cryptographically random token>`.
   Do not print or pass that token as a command argument. Ensure port 18082 is
   unused and the container uses host networking. Enable only the new selector
   service, confirm its listener is loopback-only, and keep its access logging
   disabled. No additional public firewall port is needed.

5. Install the reviewed XML as `conf/dialplan/default/20_search_numero_lines.xml`
   before numeric `90_*` routes. Keep SIP `auth-calls=true`, the authenticated
   seat in its internal context, and the public context free of these routes.
   Reload XML only; do not restart a working SIP profile or another trunk.
   Inspect loaded policy for both mappings, malformed prefixes, unauthorized
   seats, and missing Canada session/gateway cases. Preserve the old fragment
   and service state for a targeted rollback.

6. A separately authorized controlled call to a number you own is required to
   verify upstream acceptance, audio, and the caller ID actually received for
   each account. REGED, API ownership, and offline tests alone do not prove a
   successful carrier call. Inbound routing is not generated.

## Certificate-verified legacy upstream relay

`verified_relay.py` is an optional server-side transport for an existing Numero
gateway that cannot reach the provider with modern TLS. It binds only
`127.0.0.1:5061`, connects to the fixed Numero registrar, and requires both the
system CA chain and the `numeroesimapp.com` certificate hostname to verify.
Only this upstream connection permits TLS 1.0 and its necessary cipher policy.
It never disables certificate verification or changes the browser's WSS/TLS
configuration. The relay has no account credentials and never logs SIP data.

The included `search-numero-relay.service` runs it with a dynamic unprivileged
identity, a read-only filesystem, and process hardening. Its script location is
`/usr/local/lib/search-numero/verified_relay.py`. Keep that credential-free code
directory mode `0755` and the script mode `0644` so the dynamic service identity
can read it. Account XML, private line configuration, and backups stay private.
An operator must verify the
upstream certificate with the intended TLS context before deployment and keep
the relay private to the host/container network namespace. In a host-networked
FreeSWITCH container, the gateway's proxy, register-proxy, and outbound-proxy can
point at this loopback port using TCP; provider login and registration credentials
remain in the existing gateway configuration. A bridge-networked container needs
a separate reviewed network arrangement and must not expose this listener.
Use `127.0.0.1:5061;transport=tcp` for those gateway values and retain
`register-transport=tcp`. FreeSWITCH 1.10.12 constructs a registration URI by
adding its own `sip:` prefix to the `proxy` value; a `sip:` prefix in that
configuration value can therefore produce an invalid registration URI.

Back up affected configuration before installation. Enable the new service and
reload/rescan gateway XML through the server's normal operations procedure;
do not restart a working SIP profile or alter another trunk. Verify gateway
registration and both line rules after deployment. If a saved credential is
rejected, report that failure rather than silently logging in and rotating the
account's SIP password. Prefer verified modern upstream TLS when the provider
supports it.

## Approved account response parsing

The pure `credential_response.py` helper accepts the captured application-level
success code `response_code=1` and reads `data.password`. A numeric JSON password
is converted to its exact decimal string; string passwords are retained exactly.
Booleans, floats, malformed responses, and reported human-verification or account
restrictions stop the operation. HTTP 200 by itself does not establish success.
`diagnostic_metadata` retains field types, a bounded response code, and a fixed
message classification while excluding credentials, tokens, and original text.

These helpers perform no request, login, rotation, logging, or persistence. A
Numero account refresh needs the account owner's authorization because it can
invalidate another client's SIP password. An approved refresh should keep the full response in memory and save its
validated SIP credential only to that account's private server gateway XML,
with a private backup. If account-specific API selection is authorized, save
only the bound API-session fields described above in that account's separate
server file. Tokens and full responses do not belong in browser settings,
source files, process arguments, or diagnostic logs.

## References

The policy uses FreeSWITCH's ordered extensions and terminal routes from its
[XML dialplan documentation](https://developer.signalwire.com/freeswitch/dialplan/xml/),
authenticated channel fields from its
[channel variables catalog](https://developer.signalwire.com/freeswitch/reference/channel-variables/),
and caller-ID/gateway behavior from its
[gateway documentation](https://developer.signalwire.com/freeswitch/users-and-endpoints/gateways/).
