-- Invoked only by the authenticated numero-us/numero-ca dialplan gates.
-- No LuaSocket/cjson or new container package is required. The existing
-- BusyBox tools stream the private bearer into localhost nc through stdin.
local lease = nil
local released = false
local auth_file = "/usr/share/freeswitch/scripts/search-numero-selector.wgetrc"

local function digits(value, minimum, maximum)
    return type(value) == "string" and #value >= minimum and #value <= maximum
        and value:match("^[1-9]%d+$") ~= nil
end

local function quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function request(path, body, timeout)
    if (path ~= "/select" and path ~= "/release") or type(body) ~= "string"
        or #body > 2048 or not body:match("^[A-Za-z0-9_&=%-]+$")
        or type(timeout) ~= "number" or timeout % 1 ~= 0 or timeout < 1 or timeout > 20 then return nil end
    -- Only the header file's contents enter nc stdin. No bearer enters argv,
    -- environment variables, temporary files, or FreeSWITCH API events.
    -- BusyBox wget lacks GNU --config, so it cannot safely carry this header.
    local header = "s/^header[[:space:]]*=[[:space:]]*\\(Authorization:[[:space:]]*Bearer[[:space:]]*[A-Za-z0-9_-]*\\)[[:space:]]*$/\\1\\r/p"
    local command = "( { printf '%s\\r\\n' " .. quote("POST " .. path .. " HTTP/1.0")
        .. " 'Host: 127.0.0.1:18082' 'Connection: close' 'Content-Type: application/x-www-form-urlencoded'; "
        .. "/usr/bin/busybox sed -n " .. quote(header) .. " " .. quote(auth_file) .. "; "
        .. "printf 'Content-Length: %s\\r\\n\\r\\n%s' " .. quote(tostring(#body)) .. " " .. quote(body)
        .. "; } | /usr/bin/busybox timeout -s KILL " .. tostring(timeout)
        .. " /usr/bin/nc -w " .. tostring(timeout) .. " 127.0.0.1 18082 ) 2>/dev/null"
    local pipe = io.popen(command, "r")
    if not pipe then return nil end
    local raw = pipe:read(4097) or ""
    local closed, _, code = pipe:close()
    if closed ~= true or (code and code ~= 0) or #raw == 0 or #raw > 4096 then return nil end
    local status = tonumber(raw:match("^HTTP/1%.0 (%d%d%d) [^\r\n]*\r\n"))
    if status ~= 200 and status ~= 401 and status ~= 486 and status ~= 503 then return nil end
    local divider = raw:find("\r\n\r\n", 1, true)
    if not divider then return nil end
    local length = nil
    local first = true
    for line in raw:sub(1, divider + 1):gmatch("[^\r\n]+") do
        if first then first = false else
            local name, value = line:match("^([A-Za-z0-9_-]+):[ \t]*(.-)[ \t]*$")
            if not name then return nil end
            name = name:lower()
            if name == "transfer-encoding" then return nil end
            if name == "content-length" then
                if length or not value:match("^%d+$") then return nil end
                length = tonumber(value)
            end
        end
    end
    local payload = raw:sub(divider + 4)
    if not length or length ~= #payload then return nil end
    local ok, value = pcall(function() return freeswitch.JSON():decode(payload) end)
    if not ok or type(value) ~= "table" or value.status ~= status or value.ok ~= (status == 200) then return nil end
    return value
end

local function release()
    if released or not lease then return end
    released = true
    pcall(function()
        request("/release", "uuid=" .. session:get_uuid() .. "&lease=" .. lease, 2)
    end)
end

function search_numero_selection_hangup(s, status, arg)
    release()
end

local function fail(cause)
    if session and session:ready() then session:hangup(cause) end
end

local function run()
    if not session or not session:ready() then return end
    local line, destination = argv[1], argv[2]
    if (line ~= "us" and line ~= "ca") or not digits(destination, 6, 15)
        or session:getVariable("sip_authorized") ~= "true"
        or session:getVariable("sip_auth_username") ~= "1001"
        or session:getVariable("destination_number") ~= "numero-" .. line .. "-" .. destination then
        return fail("CALL_REJECTED")
    end
    local uuid = session:get_uuid()
    if type(uuid) ~= "string" or #uuid ~= 36 or not uuid:match("^[0-9a-f%-]+$") then
        return fail("CALL_REJECTED")
    end
    local answer = request("/select", "uuid=" .. uuid .. "&line=" .. line .. "&destination=" .. destination, 20)
    if not answer or answer.status ~= 200 or answer.ok ~= true then
        return fail(answer and answer.status == 486 and "USER_BUSY" or "NORMAL_TEMPORARY_FAILURE")
    end
    if type(answer.lease) ~= "string" or #answer.lease ~= 32 or not answer.lease:match("^[A-Za-z0-9_-]+$")
        or answer.gateway ~= (line == "us" and "numero" or "numero_ca")
        or not digits(answer.caller_id, 11, 11)
        or type(answer.account_user) ~= "string" or #answer.account_user < 6 or #answer.account_user > 16
        or not answer.account_user:match("^%+?%d+$") or answer.account_user == "1001" then
        return fail("NORMAL_TEMPORARY_FAILURE")
    end
    lease = answer.lease
    session:setHangupHook("search_numero_selection_hangup", "")
    if not session:ready() then return end
    session:setVariable("effective_caller_id_number", answer.caller_id)
    session:setVariable("effective_caller_id_name", answer.caller_id)
    session:setVariable("hangup_after_bridge", "true")
    session:setVariable("continue_on_fail", "false")
    session:setVariable("sip_copy_custom_headers", "false")
    session:setVariable("search_numero_gateway", answer.gateway)
    -- APK: the account URI is unchanged; the selected line changes display name.
    -- No invented PAI/RPID mixture. The account and caller ID come only from
    -- the server's verified session/owned-line allowlist, never from the tab.
    local variables = "{origination_caller_id_number=" .. answer.caller_id
        .. ",origination_caller_id_name=" .. answer.caller_id
        .. ",sip_invite_from_uri=sip:" .. answer.account_user .. "@numeroesimapp.com"
        .. ",sip_from_display=" .. answer.caller_id .. ",sip_cid_type=none,absolute_codec_string=PCMU"
        .. ",search_numero_gateway=" .. answer.gateway .. "}"
    session:execute("bridge", variables .. "sofia/gateway/" .. answer.gateway .. "/+" .. destination .. "@numeroesimapp.com")
    if session:ready() then
        local proto = session:getVariable("last_bridge_proto_specific_hangup_cause") or ""
        if proto:match("^sip:[3-6]%d%d$") then session:setVariable("proto_specific_hangup_cause", proto) end
        local cause = session:getVariable("bridge_hangup_cause") or session:getVariable("originate_disposition") or ""
        if not cause:match("^[A-Z_]+$") or cause == "SUCCESS" then cause = "NORMAL_CLEARING" end
        fail(cause)
    end
end

local ok = xpcall(run, function() return "numero_selection_failed" end)
if not ok then fail("NORMAL_TEMPORARY_FAILURE") end
release()
