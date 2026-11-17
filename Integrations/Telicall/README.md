# Telicall SIP tunnel

This credential-free systemd unit forwards the server's loopback SIP connection
at `127.0.0.1:5063` to `sip-uk-2.getcontact.com:5061` over TLS. It requires the
system CA bundle and verifies the provider's hostname. Explicit SNI selects that
hostname's certificate. The Telicall credential service and caller-ID settings
are configured separately.

The deployed host uses socat 1.8.0.0 and the Debian/Ubuntu CA bundle at
`/etc/ssl/certs/ca-certificates.crt`. Confirm the equivalent CA path before using
the unit on another distribution.

## Deploy

1. Wait for FreeSWITCH to report zero channels. Restarting the tunnel interrupts
   existing Telicall SIP connections.
2. Save the current unit in a private operator-chosen backup directory.
3. Review and validate the new unit, then install it:

   ```sh
   systemd-analyze verify Integrations/Telicall/telicall-tunnel.service
   sudo install -m 0644 Integrations/Telicall/telicall-tunnel.service /etc/systemd/system/telicall-tunnel.service
   sudo systemctl daemon-reload
   sudo systemctl restart telicall-tunnel.service
   systemctl is-active telicall-tunnel.service
   ss -ltn 'sport = :5063'
   ```

4. Confirm that port 5063 listens on `127.0.0.1` and that the running socat
   command contains `verify=1`, `cafile`, `snihost`, and `commonname` as configured.
   Confirm zero channels again before starting a separate call check.

## Certificate checks

The following bounded check opens TLS and immediately closes it without sending
SIP, requesting call credentials, or placing a call:

```sh
socat -d -d -T 5 -u /dev/null 'OPENSSL-CONNECT:sip-uk-2.getcontact.com:5061,verify=1,cafile=/etc/ssl/certs/ca-certificates.crt,snihost=sip-uk-2.getcontact.com,commonname=sip-uk-2.getcontact.com'
```

For the negative check, run the same standalone command with only
`commonname=definitely-wrong.invalid`. It must fail with a hostname mismatch.
Keep the active service's hostname unchanged.

On 2026-10-29, the actual deployed socat binary passed the positive check with
exit code 0 and reported a trusted certificate whose common name matched. The
negative check returned exit code 1 and rejected the hostname. An independent
system-CA and hostname check negotiated TLS 1.2 with
`ECDHE-ECDSA-AES256-GCM-SHA384`; the certificate's DNS SAN matched the provider
hostname. No SIP messages were sent by these probes.

The deployed unit passed `systemd-analyze verify`. After the scoped restart, the
service was active, its actual process used the verified policy, its listener
remained on loopback, and FreeSWITCH reported zero channels before and after.
PSTN calling and RTP media require a separate call check.

## Provider media

`telicall.lua` obtains per-call credentials from the loopback service and sets
`absolute_codec_string=PCMU` inside the provider leg's bridge variables. This
keeps that leg on G.711 u-law even when the local endpoint uses L16 or Opus. The
existing local-leg PCMU/PCMA setting remains for compatibility.

The 2026-10-29 regression offered only `L16/8000` and telephone events to the
provider, which returned SIP 488. The local-leg codec setting alone had not
overridden the provider leg's inherited codec. No SRTP, authentication, or TLS
settings are changed by this media repair.

Run the isolated Lua fixture from the repository root:

```sh
lua Integrations/Telicall/tests/bridge_fixture.lua
```

It executes the actual bridge script with a mocked credential service and a
local L16 endpoint, verifies the explicit provider PCMU setting and routing,
and checks unavailable and malformed credential responses. Logs contain fixed
status messages and exclude response bodies and provider authentication IDs.
The fixture makes no network requests or calls.
Install the script in the active FreeSWITCH script directory while there are
zero channels. The script loads per call; no FreeSWITCH restart is required.

## Roll back

Wait for zero channels before restoring an operator backup, then reload systemd
and restart this service. A rollback unit must retain CA and hostname
verification. If the previous unit uses `verify=0`, stop the tunnel while
repairing the verified configuration; leave calls unavailable until verification
passes. Keep account credentials and private deployment records outside this
directory.
