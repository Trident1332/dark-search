"""Execute the Lua gate with an in-memory FS/HTTP fixture; no sockets or SIP."""
from pathlib import Path
import json
import shutil
import subprocess
import unittest


LUA = shutil.which("lua")
SCRIPT = Path(__file__).resolve().parents[1] / "numero_select.lua"


@unittest.skipUnless(LUA, "Lua is required for the isolated gate fixture")
class LuaGateTests(unittest.TestCase):
    def run_gate(self, *, line="ca", gateway="numero_ca", authorized="true", state=200, wire=None, exit_code=0):
        wire = wire if wire is not None else f"HTTP/1.0 {state} Fixture\r\nContent-Length: 2\r\n\r\n{{}}"
        # Every value interpolated here is an in-repo synthetic test constant.
        harness = r'''
local requests, bridges, alive = 0, 0, true
local variables = {sip_authorized="%s", sip_auth_username="1001",
  destination_number="numero-%s-12025550125"}
local answer = {ok=%s, status=%d, lease=string.rep("s",32),
  caller_id="14165550124", account_user="447700900002", gateway="%s"}
local wire = %s
argv = {"%s", "12025550125"}
session = {}
function session:ready() return alive end
function session:get_uuid() return "11111111-1111-4111-8111-111111111111" end
function session:getVariable(key) return variables[key] end
function session:setVariable(key,value) variables[key]=value end
function session:setHangupHook(...) end
function session:hangup(cause) alive=false; print("hangup="..cause) end
function session:execute(application,data)
  assert(application=="bridge")
  bridges=bridges+1
  assert(data:find("sip_invite_from_uri=sip:447700900002@numeroesimapp.com",1,true))
  assert(data:find("sip_from_display=14165550124",1,true))
  assert(data:find("origination_caller_id_number=14165550124",1,true))
  assert(data:find("sip_cid_type=none",1,true))
  assert(data:find("absolute_codec_string=PCMU",1,true))
  assert(data:find("search_numero_gateway=%s",1,true))
  assert(data:find("sofia/gateway/%s/+12025550125@numeroesimapp.com",1,true))
  alive=false
end
io.popen=function(command)
  assert(not command:find("447700900002",1,true))
  assert(not command:find("synthetic-private-bearer",1,true))
  assert(command:find("busybox sed -n",1,true))
  assert(command:find("busybox timeout -s KILL",1,true))
  assert(command:find("127.0.0.1 18082",1,true))
  if command:find("POST /select",1,true) then
    assert(command:find("/usr/bin/nc -w 20",1,true))
  else assert(command:find("/usr/bin/nc -w 2",1,true)) end
  assert(not command:find("--config",1,true))
  requests=requests+1
  return {read=function() return wire end,close=function() return %s,"exit",%d end}
end
freeswitch={JSON=function() return {decode=function(self,payload) assert(payload=="{}");return answer end} end}
dofile(%r)
print("bridges="..bridges)
print("requests="..requests)
''' % (authorized, line, "true" if state == 200 else "false", state,
       gateway, json.dumps(wire), line, gateway, gateway, "true" if exit_code == 0 else "nil", exit_code, str(SCRIPT))
        result = subprocess.run([LUA, "-"], input=harness, capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_canada_bridge_uses_only_trusted_account_uri_and_canada_gateway(self):
        output = self.run_gate()
        self.assertIn("bridges=1", output)
        self.assertIn("requests=2", output)  # Selection + bounded final release.

    def test_canada_reply_cannot_fall_back_to_us_gateway(self):
        output = self.run_gate(gateway="numero")
        self.assertIn("bridges=0", output)
        self.assertIn("hangup=NORMAL_TEMPORARY_FAILURE", output)

    def test_us_keeps_its_existing_gateway_and_has_explicit_uri_override(self):
        self.assertIn("bridges=1", self.run_gate(line="us", gateway="numero"))

    def test_unapproved_channel_cannot_contact_selector(self):
        output = self.run_gate(authorized="false")
        self.assertIn("requests=0", output)
        self.assertIn("bridges=0", output)

    def test_account_busy_does_not_bridge_or_fall_through(self):
        output = self.run_gate(state=486)
        self.assertIn("bridges=0", output)
        self.assertIn("hangup=USER_BUSY", output)

    def test_truncated_extra_redirect_or_malformed_http_fails_closed(self):
        responses = [
            "HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\n{}",
            "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\n{}extra",
            "HTTP/1.0 302 Found\r\nContent-Length: 2\r\n\r\n{}",
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}",
            "HTTP/1.0 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
            "HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 2\r\n\r\n{}",
            "HTTP/1.0 200 OK\r\n\r\n{}",
            "HTTP/1.0 200 OK\r\nmalformed\r\nContent-Length: 2\r\n\r\n{}",
            "HTTP/1.0 503 Failed\r\nContent-Length: 2\r\n\r\n{}",
            "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\n" + "x" * 4096,
        ]
        for response in responses:
            with self.subTest(response=response[:30]):
                self.assertIn("bridges=0", self.run_gate(wire=response))

    def test_nonzero_transport_exit_fails_closed_even_with_successful_body(self):
        self.assertIn("bridges=0", self.run_gate(exit_code=1))


if __name__ == "__main__": unittest.main()
