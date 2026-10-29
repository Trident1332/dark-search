# Owned Numero lines through FreeSWITCH

This package adds outbound US/Canada line selection to Search's existing
FreeSWITCH connection. Both owned numbers use the existing, registered Numero
gateway and its one account. Numero login, password rotation, SIP registration,
TLS settings, and credentials remain under the server's existing management.
This generator makes no network requests and does not deploy or modify files.
It requires Python 3.10 or later and uses only the standard library.

## Browser/server contract

Search sends one of these SIP Request-URI user parts to its configured
FreeSWITCH domain:

- `numero-us-<E164digits>` selects the server's allowlisted US DID.
- `numero-ca-<E164digits>` selects the server's allowlisted Canadian DID.

`<E164digits>` is the **destination**, without `+`: 6–15 ASCII digits, starting
with 1–9. Feature codes and short seat extensions do not use this contract.
The request does not contain a caller-ID number. The server maps the two fixed
line IDs to owned caller IDs; it never trusts a caller ID sent in SIP headers.
Both routes bridge to `sofia/gateway/<configured-gateway>/+<E164digits>@numeroesimapp.com`.
Configured caller IDs are canonical `+1…` values; outbound caller-ID fields use
the same bare country-code digits as the existing Numero trunk. Destination
numbers keep their leading `+` on the upstream bridge.

Each successful route requires both `sip_authorized=true` and the configured
`sip_auth_username`. A final rejection rule catches all remaining `numero-*`
destinations, including unknown countries, malformed numbers, uppercase forms,
and requests from other or unauthenticated seats. They end with `CALL_REJECTED`.
The prefix prevents an older numeric-only `90_numero_out.xml` from silently
placing a Canadian-line request through its old default caller ID if these new
rules have not been installed.

## Private configuration

Create a JSON file outside the checkout, readable only by its operator. It has
exactly three top-level keys:

| Key | Value |
| --- | --- |
| `gateway` | Existing gateway name, normally `numero` |
| `authorized_seat` | Authenticated browser seat, such as `1001` |
| `lines` | Object containing exactly `us` and `ca`, each a different owned `+1` NANP DID |

Do not put Numero account passwords, app login data, or browser seat passwords
in this file. Both US and Canada use country code `+1`; the administrator must
map each verified owned number to its correct country. Format validation does
not establish ownership or determine a number's country.

The Python API for a native configuration exporter is:

```python
generate({
    "gateway": gateway_name,
    "authorized_seat": authenticated_seat,
    "lines": {"us": owned_us_e164, "ca": owned_canadian_e164},
})
```

Import `generate_dialplan.py` with `importlib.util`; `validate(config)` returns
a canonical independent dictionary and `generate(config)` returns XML text.
Invalid input raises `ConfigurationError` without including supplied values.
`load_config(Path(...))` also rejects duplicate JSON keys and oversized files.

## Generate and review

1. Run the offline tests from the checkout:

   ```sh
   python3 -m unittest discover -s Integrations/Numero/tests -v
   ```

2. Generate a candidate in a private directory. Substitute your existing private
   configuration path and a **new** output filename:

   ```sh
   python3 Integrations/Numero/generate_dialplan.py /private/path/numero-lines.json \
     --output /private/path/20_search_numero_lines.xml
   ```

   Output files use mode `0600`; the generator refuses to overwrite an existing
   file. Without `--output`, XML is written to standard output and contains the
   owned caller IDs. Avoid putting that output in shared logs.

3. Before installing, verify the selected existing gateway has exactly one
   `<param name="caller-id-in-from" value="true"/>`. The generator can check
   the server's existing gateway file without changing its credentials:

   ```sh
   python3 generate_dialplan.py /private/path/numero-lines.json \
     --gateway-xml /etc/freeswitch/sip_profiles/external/numero.xml \
     --output /private/path/20_search_numero_lines.checked.xml
   ```

   This is a required deployment check. A gateway with `caller-id-in-from`
   disabled can substitute its account identity instead of the chosen DID.

4. Review the candidate. Install it as
   `conf/dialplan/default/20_search_numero_lines.xml` using your deployment
   process, before the existing numeric `90_*` routes. Confirm `default.xml`
   includes these fragments in filename order and has no earlier catch-all
   that captures `numero-*`. Keep the authenticated browser directory user's
   `user_context` set to this internal context. Require SIP call authentication
   (`auth-calls=true`) on that profile; do not bypass it with a permissive ACL.
   Do not include these outbound routes in the unauthenticated public context.
   Reload the XML through the server's normal operations procedure.

5. Inspect routing for both line IDs, malformed prefixes, and an unauthorized
   seat. These offline tests validate generated policy and XML; they do not run
   FreeSWITCH. A controlled call to a number you own is still needed to verify
   the deployed rules, upstream acceptance, and the caller ID actually received
   for **each** owned DID. The provider may reject or replace a requested DID;
   a successful SIP registration does not establish both identities work.

Inbound routing is deliberately not generated. It needs verified provider
ingress identity, public-context checks, and the server's actual DID delivery
format. No account login or password rotation is needed just to select a line.

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
invalidate another client's SIP password. An approved refresh should keep the
response in memory and write only its validated SIP credential to the owned
server gateway XML, with a private backup; account tokens and full responses do
not belong in browser settings, source files, or diagnostic logs.

## References

The policy uses FreeSWITCH's ordered extensions and terminal routes from its
[XML dialplan documentation](https://developer.signalwire.com/freeswitch/dialplan/xml/),
authenticated channel fields from its
[channel variables catalog](https://developer.signalwire.com/freeswitch/reference/channel-variables/),
and caller-ID/gateway behavior from its
[gateway documentation](https://developer.signalwire.com/freeswitch/users-and-endpoints/gateways/).
