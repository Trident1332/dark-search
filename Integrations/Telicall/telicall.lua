-- /usr/share/freeswitch/scripts/telicall.lua
-- Per-call Telicall trunk: fetch ephemeral SIP credentials from the local creds service,
-- then bridge the browser call out to sip-uk-2.getcontact.com with those credentials.
-- Telicall issues fresh username/password for EVERY call, so there is no standing gateway.
--
-- Dialplan: <action application="lua" data="telicall.lua +$1"/>
-- Requires: mod_lua, mod_curl, and the telicall-creds service on 127.0.0.1:8788.
--
-- The provider supports TLS 1.2 with a publicly trusted certificate. The default
-- route sends TCP over loopback to telicall-tunnel.service on 127.0.0.1:5063,
-- which verifies the provider's CA chain and hostname and supplies SNI. The
-- Request-URI still names the provider; sip_route_uri selects the transport hop.
-- DIRECT_TLS is an untested alternate. Before enabling it, configure and verify
-- the external profile's native TLS and certificate policy.

local CREDS_URL = "http://127.0.0.1:8788/allocate"
local TUNNEL    = "127.0.0.1:5063"   -- socat TCP->TLS to sip-uk-2.getcontact.com:5061
local DIRECT_TLS = false             -- true = originate TLS straight to getcontact instead

local dest = argv[1]
if not dest or dest == "" then dest = session:getVariable("destination_number") end
local num = tostring(dest):gsub("[^%d+]", "")
if num:sub(1, 1) ~= "+" then num = "+" .. num end

-- 1) fetch per-call credentials (newline format: ok / user / pass / domain / port / proto / callId)
local api = freeswitch.API()
local resp = api:execute("curl", CREDS_URL .. "?to=" .. num .. "&format=fs get")
local lines = {}
for line in tostring(resp):gmatch("[^\r\n]+") do lines[#lines + 1] = line end

local function unavailable()
  freeswitch.consoleLog("ERR", "[telicall] credentials unavailable\n")
  if session:ready() then session:hangup("SERVICE_UNAVAILABLE") end
end

if #lines ~= 7 or lines[1] ~= "ok" then
  unavailable()
  return
end

local username, password, domain, port, protocol, callId =
  lines[2], lines[3], lines[4], lines[5], lines[6], lines[7]

-- Reject malformed or delimiter-bearing data before building bridge variables.
for _, value in ipairs(lines) do
  if #value > 4096 or value:find("[%z,{}]") or value:find("'", 1, true)
      or value:find('"', 1, true) or value:find("\\", 1, true) then
    unavailable()
    return
  end
end
if not domain:match("^[%w%.%-]+$") or not port:match("^%d+$")
    or tonumber(port) < 1 or tonumber(port) > 65535 or not protocol:match("^%a+$") then
  unavailable()
  return
end

freeswitch.consoleLog("INFO", "[telicall] connecting through verified gateway\n")

-- 2) bridge out. Ephemeral username/password answer the 407 challenge inline; From is the
--    per-call AOR the server correlates the callId to. FreeSWITCH transcodes the browser's
--    Opus/DTLS-SRTP to PCMU toward Telicall (same as the Numero trunk).
session:execute("set", "hangup_after_bridge=true")
session:execute("set", "continue_on_fail=false")
session:execute("set", "absolute_codec_string=PCMU,PCMA")

-- Bind the provider leg explicitly; the local leg may use L16 or Opus.
local vlist = {
  "absolute_codec_string=PCMU",
  "sip_auth_username=" .. username,
  "sip_auth_password=" .. password,
  "sip_from_uri=" .. username .. "@" .. domain,
  "sip_invite_domain=" .. domain,
  "sip_h_X-Teli-CallId=" .. tostring(callId),
}

local dialstr
if DIRECT_TLS then
  -- straight to the provider over TLS (external_ssl_enable must be true)
  dialstr = string.format("{%s}sofia/external/sip:%s@%s:%s;transport=tls",
    table.concat(vlist, ","), num, domain, port)
else
  -- plain TCP to the local tunnel; the Request-URI still names the real getcontact host,
  -- sip_route_uri makes the tunnel the outbound proxy hop
  vlist[#vlist + 1] = "sip_route_uri=sip:" .. TUNNEL .. ";transport=tcp"
  dialstr = string.format("{%s}sofia/external/sip:%s@%s;transport=tcp",
    table.concat(vlist, ","), num, domain)
end

session:execute("bridge", dialstr)
