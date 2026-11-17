-- Offline fixture: no FreeSWITCH, credentials, sockets, or carrier requests.
local source = arg[1] or "Integrations/Telicall/telicall.lua"

local function run(response)
  local state = { apiCalls = 0, commands = {}, variables = { read_codec = "L16" }, logs = {} }
  local environment = {
    argv = { "+12025550123" }, string = string, table = table, tostring = tostring,
    ipairs = ipairs, tonumber = tonumber,
    freeswitch = {
      API = function()
        return { execute = function(_, command, request)
          assert(command == "curl")
          assert(request == "http://127.0.0.1:8788/allocate?to=+12025550123&format=fs get")
          state.apiCalls = state.apiCalls + 1
          return response
        end }
      end,
      consoleLog = function(_, message) state.logs[#state.logs + 1] = message end,
    },
    session = {
      getVariable = function(_, key) return state.variables[key] end,
      ready = function() return true end,
      hangup = function(_, cause) state.hangup = cause end,
      execute = function(_, command, data)
        state.commands[#state.commands + 1] = { command = command, data = data }
        if command == "set" then
          local key, value = data:match("^([^=]+)=(.*)$")
          state.variables[key] = value
        elseif command == "bridge" then
          assert(state.bridge == nil, "only one bridge is permitted")
          state.bridge = data
        else error("unexpected application") end
      end,
    },
  }
  assert(loadfile(source, "t", environment))()
  return state
end

local state = run(table.concat({ "ok", "fixture-user", "fixture-password", "sip.example.test",
                                 "5061", "tls", "fixture-call-id", "" }, "\n"))
assert(state.apiCalls == 1)
assert(state.variables.read_codec == "L16", "local media remains independent")
assert(state.variables.absolute_codec_string == "PCMU,PCMA", "preserve existing local-leg compatibility")
assert(state.bridge ~= nil and state.hangup == nil)
local block, endpoint = state.bridge:match("^%{(.-)%}(.*)$")
assert(block and endpoint)
local provider = {}
for item in block:gmatch("[^,]+") do
  local key, value = item:match("^([^=]+)=(.*)$")
  assert(key and provider[key] == nil, "each bridge variable must be complete and unique")
  provider[key] = value
end
assert(provider.absolute_codec_string == "PCMU", "provider must override inherited L16 with PCMU")
assert(provider.sip_auth_username == "fixture-user")
assert(provider.sip_auth_password == "fixture-password")
assert(provider.sip_from_uri == "fixture-user@sip.example.test")
assert(provider["sip_h_X-Teli-CallId"] == "fixture-call-id")
assert(provider.sip_route_uri == "sip:127.0.0.1:5063;transport=tcp")
assert(endpoint == "sofia/external/sip:+12025550123@sip.example.test;transport=tcp")
for _, message in ipairs(state.logs) do
  assert(not message:find("fixture-password", 1, true), "never log the SIP password")
  assert(not message:find("fixture-user", 1, true), "never log the SIP username")
  assert(not message:find("fixture-call-id", 1, true), "never log the provider call ID")
end

local unavailable = run("error\nfixture-unavailable\n")
assert(unavailable.apiCalls == 1)
assert(unavailable.bridge == nil)
assert(unavailable.hangup == "SERVICE_UNAVAILABLE")

for _, malformed in ipairs({
  "ok\nfixture-user\nfixture-secret-password\n",
  "error\nfixture-secret-password\n",
  "ok\nfixture-user\nfixture-secret-password,unsafe=1\nsip.example.test\n5061\ntls\nfixture-call-id\n",
}) do
  local rejected = run(malformed)
  assert(rejected.bridge == nil, "malformed credentials must never reach bridge")
  assert(rejected.hangup == "SERVICE_UNAVAILABLE")
  for _, message in ipairs(rejected.logs) do
    assert(message == "[telicall] credentials unavailable\n")
    assert(not message:find("fixture-secret-password", 1, true))
  end
end
print("Telicall bridge fixtures passed (provider codec, unavailable service, malformed secret redaction)")
