module("luci.controller.modemmanager", package.seeall)
require("luci.util")

local at_lock = "/tmp/modem-at.lock"
local at_lock_owner = nil

local function acquire_at_lock()
    if luci.sys.call("mkdir " .. at_lock .. " 2>/dev/null") ~= 0 then
        local owner_file = io.open(at_lock .. "/pid", "r")
        local owner = owner_file and tonumber(owner_file:read("*l") or "") or nil
        if owner_file then owner_file:close() end
        if owner and luci.sys.call("kill -0 " .. owner .. " 2>/dev/null") == 0 then
            return false
        end
        luci.sys.call("rm -f " .. at_lock .. "/pid; rmdir " .. at_lock .. " 2>/dev/null")
        if luci.sys.call("mkdir " .. at_lock .. " 2>/dev/null") ~= 0 then
            return false
        end
    end

    local owner_file = io.open(at_lock .. "/pid", "w")
    if not owner_file then
        luci.sys.call("rmdir " .. at_lock .. " 2>/dev/null")
        return false
    end
    local nixio = require("nixio")
    at_lock_owner = tostring(nixio.getpid())
    owner_file:write(at_lock_owner, "\n")
    owner_file:close()
    return true
end

local function release_at_lock()
    local owner_file = io.open(at_lock .. "/pid", "r")
    local owner = owner_file and owner_file:read("*l") or nil
    if owner_file then owner_file:close() end
    if at_lock_owner and owner == at_lock_owner then
        luci.sys.call("rm -f " .. at_lock .. "/pid; rmdir " .. at_lock .. " 2>/dev/null")
    end
    at_lock_owner = nil
end

function index()
    entry({"admin", "network", "modemmanager"}, template("modemmanager/view"), _("Cellular Manager"), 60).dependent = true
    -- Hidden action entries (not shown in navigation)
    entry({"admin", "network", "modemmanager", "reinit"}, call("action_reinit")).leaf = true
    entry({"admin", "network", "modemmanager", "reboot"}, call("action_reboot")).leaf = true
    entry({"admin", "network", "modemmanager", "save"}, call("action_save")).leaf = true
    entry({"admin", "network", "modemmanager", "at"}, call("action_at")).leaf = true
    entry({"admin", "network", "modemmanager", "log"}, call("action_log")).leaf = true
    entry({"admin", "network", "modemmanager", "signal"}, call("action_signal")).leaf = true
    entry({"admin", "network", "modemmanager", "status"}, call("action_status")).leaf = true
    entry({"admin", "network", "modemmanager", "sms"}, post("action_sms")).leaf = true
    entry({"admin", "network", "modemmanager", "sms-settings"}, post("action_sms_settings")).leaf = true
    entry({"admin", "network", "modemmanager", "sms-delete"}, post("action_sms_delete")).leaf = true
    entry({"admin", "network", "modemmanager", "sms-send"}, post("action_sms_send")).leaf = true
end

function action_reinit()
    luci.sys.call("/usr/bin/modem-reinit >/tmp/modem-reinit.log 2>&1")
    luci.http.redirect(luci.dispatcher.build_url("admin", "network", "modemmanager"))
end

function action_reboot()
    luci.sys.call("/usr/bin/modem-reboot >/tmp/modem-reboot.log 2>&1")
    luci.http.redirect(luci.dispatcher.build_url("admin", "network", "modemmanager"))
end

function action_save()
    local enabled = luci.http.formvalue("enabled") or "0"
    local enable_ipv6 = luci.http.formvalue("enable_ipv6") or "0"

    luci.sys.call("uci set modemmanager.main.enabled='" .. enabled .. "'")
    luci.sys.call("uci set modemmanager.main.enable_ipv6='" .. enable_ipv6 .. "'")
    luci.sys.call("uci commit modemmanager")

    if enabled == "0" then
        luci.sys.call("/etc/init.d/modem-manager stop >/dev/null 2>&1")
        luci.sys.call("rm -f /tmp/modem-state")
    else
        luci.sys.call("/etc/init.d/modem-manager restart >/dev/null 2>&1")
    end

    luci.http.redirect(luci.dispatcher.build_url("admin", "network", "modemmanager"))
end

function action_at()
    local cmd = luci.http.formvalue("cmd") or ""
    if cmd == "" then
        luci.http.prepare_content("text/plain")
        luci.http.write("ERROR: No command specified")
        return
    end

    -- Detect AT tool
    local at_tool = ""
    if luci.sys.call("command -v sms_tool_q >/dev/null 2>&1") == 0 then
        at_tool = "sms_tool_q"
    elseif luci.sys.call("command -v sms_tool >/dev/null 2>&1") == 0 then
        at_tool = "sms_tool"
    else
        luci.http.prepare_content("text/plain")
        luci.http.write("ERROR: No AT tool found (sms_tool / sms_tool_q)")
        return
    end

    if not acquire_at_lock() then
        luci.http.prepare_content("text/plain")
        luci.http.write("ERROR: AT port busy with another modem request")
        return
    end

    -- Prefer the watchdog-confirmed AT port, then probe the remaining
    -- allowlisted devices. A character device alone is not proof that it is
    -- an AT command port (for example, Sierra exposes other ttyUSB ports).
    local at_devices = { "/dev/wwan0at0", "/dev/ttyUSB2", "/dev/ttyUSB1", "/dev/ttyUSB0", "/dev/mhi_DUN", "/dev/mhi_AT" }
    local allowed = {}
    local candidates = {}
    local seen = {}
    for _, dev in ipairs(at_devices) do
        allowed[dev] = true
    end

    local preferred = get_modem_state().at_device
    if preferred and allowed[preferred] then
        table.insert(candidates, preferred)
        seen[preferred] = true
    end
    for _, dev in ipairs(at_devices) do
        if not seen[dev] then
            table.insert(candidates, dev)
            seen[dev] = true
        end
    end

    local function response_has_ok(response)
        for line in (response or ""):gmatch("[^\r\n]+") do
            if line:match("^%s*OK%s*$") then
                return true
            end
        end
        return false
    end

    local at_device = ""
    for _, dev in ipairs(candidates) do
        local quoted_dev = luci.util.shellquote(dev)
        if luci.sys.call("[ -c " .. quoted_dev .. " ]") == 0 then
            local probe = luci.sys.exec(at_tool .. " -D -d " .. quoted_dev .. " at AT 2>&1")
            if response_has_ok(probe) then
                at_device = dev
                break
            end
        end
    end

    if at_device == "" then
        release_at_lock()
        luci.http.prepare_content("text/plain")
        luci.http.write("ERROR: No responsive AT port found")
        return
    end

    -- Execute AT command
    local result = luci.sys.exec(at_tool .. " -D -d " .. luci.util.shellquote(at_device) .. " at " .. luci.util.shellquote(cmd) .. " 2>&1")
    release_at_lock()
    luci.http.prepare_content("text/plain")
    luci.http.write(result)
end

function action_log()
    luci.http.prepare_content("text/plain")
    local f = io.open("/tmp/modem-watchdog.log", "r")
    if f then
        local lines = {}
        for line in f:lines() do
            table.insert(lines, line)
            if #lines > 50 then
                table.remove(lines, 1)
            end
        end
        f:close()
        luci.http.write(table.concat(lines, "\n"))
    else
        luci.http.write("No log file found")
    end
end

function action_status()
    luci.http.prepare_content("text/plain")
    local f = io.open("/tmp/modem-state", "r")
    if f then
        luci.http.write(f:read("*a") or "")
        f:close()
    else
        luci.http.write("status=disabled\n")
    end
end

function action_signal()
    luci.http.prepare_content("text/plain")

    -- Check modem is connected (state file exists)
    local state = get_modem_state()
    if not state.status or state.status == "no_modem" then
        luci.http.write("ERROR: Modem not available")
        return
    end

    -- Run signal collection script
    local result = luci.sys.exec("/usr/bin/modem-signal 2>&1")
    if result == "" or result:match("^ERROR") then
        luci.http.write(result ~= "" and result or "ERROR: No signal data returned")
        return
    end

    luci.http.write(result)
end

function action_sms()
    luci.http.header("Cache-Control", "no-store")
    luci.http.prepare_content("application/json")

    local json = require("luci.jsonc")
    local result = luci.sys.exec("/usr/bin/modem-sms 2>/dev/null")
    local data = json.parse(result or "")
    if type(data) ~= "table" or type(data.messages) ~= "table" then
        luci.http.status(502, "Bad Gateway")
        luci.http.write('{"error":"SMS reader failed. Try Refresh.","messages":[],"warnings":[]}')
        return
    end

    if data.error then
        luci.http.status(503, "Service Unavailable")
    end
    luci.http.write(result)
end

local function valid_sms_memory(value)
    return value == "ME" or value == "MT" or value == "SM" or value == "SR"
end

function action_sms_settings()
    luci.http.header("Cache-Control", "no-store")
    luci.http.prepare_content("application/json")

    local mem1 = luci.http.formvalue("mem1") or ""
    local mem2 = luci.http.formvalue("mem2") or ""
    local mem3 = luci.http.formvalue("mem3") or ""
    if not valid_sms_memory(mem1) or not valid_sms_memory(mem2) or not valid_sms_memory(mem3) then
        luci.http.status(400, "Bad Request")
        luci.http.write('{"error":"Invalid SMS storage selection."}')
        return
    end

    local uci = require("luci.model.uci").cursor()
    uci:set("modemmanager", "main", "sms_mem1", mem1)
    uci:set("modemmanager", "main", "sms_mem2", mem2)
    uci:set("modemmanager", "main", "sms_mem3", mem3)
    if not uci:commit("modemmanager") then
        luci.http.status(500, "Internal Server Error")
        luci.http.write('{"error":"Could not save SMS storage settings."}')
        return
    end

    luci.http.write(string.format('{"saved":true,"storage":{"mem1":"%s","mem2":"%s","mem3":"%s"}}', mem1, mem2, mem3))
end

function action_sms_delete()
    luci.http.header("Cache-Control", "no-store")
    luci.http.prepare_content("application/json")

    local indexes = luci.http.formvalue("indexes") or ""
    local mem1 = luci.http.formvalue("mem1") or ""
    if #indexes > 1024 or not indexes:match("^%d+[,0-9]*$") or indexes:match(",$") or indexes:match(",,") or not valid_sms_memory(mem1) then
        luci.http.status(400, "Bad Request")
        luci.http.write('{"error":"Invalid SMS delete request."}')
        return
    end
    for index in indexes:gmatch("[^,]+") do
        local number = tonumber(index)
        if not number or number < 0 or number > 2147483647 or number ~= math.floor(number) then
            luci.http.status(400, "Bad Request")
            luci.http.write('{"error":"Invalid SMS message index."}')
            return
        end
    end

    local json = require("luci.jsonc")
    local command = "/usr/bin/modem-sms --delete " .. luci.util.shellquote(indexes) .. " " .. luci.util.shellquote(mem1) .. " 2>/dev/null"
    local result = luci.sys.exec(command)
    local data = json.parse(result or "")
    if type(data) ~= "table" then
        luci.http.status(502, "Bad Gateway")
        luci.http.write('{"error":"SMS deletion failed. Refresh and try again."}')
        return
    end
    if data.code == "storage_changed" then
        luci.http.status(409, "Conflict")
    elseif data.error or type(data.failed) ~= "table" or #data.failed > 0 then
        luci.http.status(502, "Bad Gateway")
    end
    luci.http.write(result)
end

function action_sms_send()
    luci.http.header("Cache-Control", "no-store")
    luci.http.prepare_content("application/json")

    local recipient = luci.http.formvalue("recipient") or ""
    local message = luci.http.formvalue("message") or ""
    local number = recipient:gsub("^%+", "")
    if #recipient > 21 or #number < 1 or #number > 20 or not number:match("^%d+$") then
        luci.http.status(400, "Bad Request")
        luci.http.write('{"error":"Enter a valid destination number."}')
        return
    end
    if #message < 1 or #message > 1024 then
        luci.http.status(400, "Bad Request")
        luci.http.write('{"error":"Enter a valid single SMS message."}')
        return
    end

    local json = require("luci.jsonc")
    local command = "/usr/bin/modem-sms --send " .. luci.util.shellquote(recipient) .. " " .. luci.util.shellquote(message) .. " 2>/dev/null"
    local result = luci.sys.exec(command)
    local data = json.parse(result or "")
    if type(data) ~= "table" then
        luci.http.status(502, "Bad Gateway")
        luci.http.write('{"error":"SMS sending failed. Try again."}')
        return
    end
    if data.code == "send_unsupported" then
        luci.http.status(409, "Conflict")
    elseif data.error or data.sent ~= true then
        luci.http.status(502, "Bad Gateway")
    end
    luci.http.write(result)
end

function get_modem_state()
    local state = {}
    local f = io.open("/tmp/modem-state", "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^(%S+)=(.+)$")
            if k then state[k] = v end
        end
        f:close()
    end
    return state
end
