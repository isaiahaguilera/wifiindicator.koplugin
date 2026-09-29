--[[--
Non-blocking Wi-Fi connect engine for Kobo (wpa_supplicant).

Stock KOReader connects on the UI thread and drives wpa_supplicant itself: scan, then try
KOReader's saved networks one at a time (up to 30 s each), then DHCP. wpa_supplicant is
started with the Kobo OS's own config, so it already joins the Kobo OS's networks by itself,
while networks saved only in KOReader never come back on wake (restore-wifi-async.sh only
waits for wpa_supplicant).

This engine instead hands every KOReader-saved network to wpa_supplicant as soon as it is up
and lets wpa_supplicant pick. See docs/plan-wpa-handoff.md.

Slow steps (hardware bring-up, DHCP, the fallback scan) run in forked subprocesses and
association is polled every 250 ms, so the UI thread never blocks. The engine shows no popups
of its own: it reports its state through M.on_status(state, info), and main.lua decides how
to present it. The latest one is kept in M.state. States:
  "connecting"; "connected" (info.ssid); "problem" (something actually went wrong);
  "choose" (nothing to join, the network list is up for the user); "off" (a background
  restore quietly gave up); "idle" (the attempt was cancelled).

The top part is pure logic with no KOReader dependencies, so test/test_wificonnect.lua can
exercise it on a desktop LuaJIT. M.install() hooks NetworkMgr.
]]--

local M = {
    installed = false,
    on_status = function(state, info) end, -- replaced by main.lua
    state = nil, -- the latest reported state
}

-- wpa_supplicant escapes non-printable SSID bytes as \xNN, and backslashes as \\.
-- (Same decoding as KOReader's WpaSupplicant.)
function M.decodeSSID(ssid)
    local decoded = ssid:gsub("%f[\\]\\x(%x%x)", function(b)
        local c = string.char(tonumber(b, 16))
        return c == "\\" and "\\\\" or c
    end)
    return (decoded:gsub("\\\\", "\\"))
end

function M.toHex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- Does this KOReader network need its PSK derived (PBKDF2) before it can be handed over?
function M.needsPsk(nw)
    return type(nw.password) == "string" and nw.password ~= "" and not nw.psk
end

-- The SET_NETWORK key/value pairs for a KOReader network entry, or nil if it can't be used
-- as is. An empty password means an open network (KOReader's convention).
function M.networkParams(nw)
    if type(nw) ~= "table" or type(nw.ssid) ~= "string" or nw.ssid == "" then
        return nil
    end
    local params = { { "ssid", M.toHex(nw.ssid) } }
    if nw.password == "" then
        params[2] = { "key_mgmt", "NONE" }
    elseif type(nw.psk) == "string" and nw.psk ~= "" then
        params[2] = { "psk", nw.psk }
    else
        return nil
    end
    return params
end

-- The KOReader-saved networks that wpa_supplicant doesn't already have, sorted by SSID.
-- saved: NetworkMgr:getAllSavedNetworks().data (keyed by SSID).
-- known: WpaClient:listNetworks() (SSIDs in wpa_supplicant's escaped form).
function M.pickNetworks(saved, known)
    local have = {}
    for _, nw in ipairs(known or {}) do
        if type(nw.ssid) == "string" then
            have[M.decodeSSID(nw.ssid)] = true
        end
    end
    local picked = {}
    for _, nw in pairs(saved or {}) do
        if type(nw) == "table" and type(nw.ssid) == "string" and nw.ssid ~= ""
                and not have[nw.ssid] and (nw.password or nw.psk) then
            table.insert(picked, nw)
        end
    end
    table.sort(picked, function(a, b) return a.ssid < b.ssid end)
    return picked
end

local POLL_INTERVAL = 0.25
local BRINGUP_TIMEOUT_S = 30
local JOIN_TIMEOUT_S = 15 -- same as restore-wifi-async.sh
local DHCP_TIMEOUT_S = 30
local SCAN_TIMEOUT_S = 30

-- Hooks NetworkMgr. Returns whether the engine is active. Safe to call more than once
-- (the plugin is instantiated for both FileManager and ReaderUI).
function M.install()
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr._nbwifi_installed then
        -- Already installed by us, or by the standalone koreader-nonblocking-wifi patch.
        M.installed = NetworkMgr._nbwifi_installed == "wifiindicator"
        return M.installed
    end
    if not NetworkMgr.wpa_supplicant then
        return false -- not a wpa_supplicant device: nothing to do
    end
    NetworkMgr._nbwifi_installed = "wifiindicator"
    M.installed = true

    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")
    local WpaClient = require("lj-wpaclient/wpaclient")
    local buffer = require("string.buffer")
    local crypto = require("ffi/crypto")
    local ffi = require("ffi")
    local ffiutil = require("ffi/util")
    local logger = require("logger")
    local time = require("ui/time")
    local _ = require("gettext")
    local unpack = unpack or table.unpack -- luacheck: ignore

    -- The plugin menu toggle; off means pure stock behavior. Checked at each entry point,
    -- so it takes effect on the next connection attempt.
    local function enabled()
        return G_reader_settings:nilOrTrue("wifiindicator_nonblocking_wifi")
    end

    local function report(state, info)
        M.state = state
        M.on_status(state, info)
    end

    -- Generation counter: bumping it cancels every in-flight async step. Bumped by any
    -- Wi-Fi teardown, and by each new connection attempt (the latest attempt wins).
    local gen = 0
    for __, method in ipairs({ "disableWifi", "_abortWifiConnection" }) do
        local orig = NetworkMgr[method]
        NetworkMgr[method] = function(self, ...)
            gen = gen + 1
            if M.state == "connecting" then
                M.state = "idle" -- cancelled; KOReader's own events report the outcome
            end
            return orig(self, ...)
        end
    end
    local function start()
        gen = gen + 1
        report("connecting")
    end

    -- NEVER use ffiutil.readAllFromFD() here: it blocks until *every* copy of the
    -- pipe's write end is closed. The wifi helper scripts spawn daemons that inherit
    -- our write end (their fd-hygiene preamble closes sockets and files but skips
    -- pipes) and keep it open forever: enable-wifi.sh -> `wpa_supplicant -B`,
    -- obtain-ip.sh -> dhcpcd. The blocking read then hangs the UI thread for good;
    -- on a real device that's a hard lock only the power button gets you out of.
    -- Instead, drain only what FIONREAD reports is already in the pipe.
    local function drainPipe(fd, chunks)
        while true do
            local n = ffiutil.getNonBlockingReadSize(fd)
            if not n or n <= 0 then break end
            local buf = ffi.new("char[?]", n)
            local nr = tonumber(ffi.C.read(fd, buf, n))
            if not nr or nr <= 0 then break end
            chunks[#chunks + 1] = ffi.string(buf, nr)
        end
    end

    -- Run task() in a forked child, deliver its return values to on_done(ok, ...)
    -- without ever blocking the UI loop. on_done(false) on spawn failure or timeout;
    -- not called at all if the attempt is cancelled (see gen).
    local function subprocessCall(task, timeout_s, on_done)
        local my_gen = gen
        local pid, parent_read_fd = ffiutil.runInSubProcess(function(__, child_write_fd)
            -- Belt: don't leak our pipe into anything the task execs, so daemons
            -- spawned by the wifi scripts can't hold the write end open (see above).
            -- F_SETFD = 2, FD_CLOEXEC = 1 (POSIX; ffi.C.F_SETFD is missing in older releases)
            pcall(function() ffi.C.fcntl(child_write_fd, 2, ffi.cast("int", 1)) end)
            local results = table.pack(task())
            local ok, str = pcall(buffer.encode, results)
            if not ok then
                logger.warn("wificonnect: cannot serialize subprocess result:", str)
                str = buffer.encode({ n = 0 })
            end
            ffiutil.writeToFD(child_write_fd, str, true)
        end, true)
        if not pid then
            on_done(false)
            return
        end

        local chunks = {}
        local function closePipe()
            if parent_read_fd then
                ffi.C.close(parent_read_fd)
                parent_read_fd = nil
            end
        end

        -- Reap the zombie after teardown/timeout; the pipe is already closed then.
        local function collect()
            if not ffiutil.isSubProcessDone(pid) then
                UIManager:scheduleIn(1, collect)
            end
        end

        local deadline = time.monotonic() + time.s(timeout_s)
        local function check()
            if gen ~= my_gen then -- connection attempt torn down under us
                ffiutil.terminateSubProcess(pid)
                closePipe()
                UIManager:scheduleIn(1, collect)
                return
            end
            if parent_read_fd then
                -- Suspenders: consume as data comes, so a child writing a result
                -- larger than the pipe buffer can't get stuck (and thus never exit).
                drainPipe(parent_read_fd, chunks)
            end
            if ffiutil.isSubProcessDone(pid) then
                if parent_read_fd then
                    drainPipe(parent_read_fd, chunks) -- catch bytes written right before exit
                    closePipe()
                end
                local ret
                local data = table.concat(chunks)
                if #data > 0 then
                    local ok, t = pcall(buffer.decode, data)
                    if ok then ret = t end
                end
                if ret then
                    on_done(true, unpack(ret, 1, ret.n))
                else
                    on_done(true)
                end
            elseif time.monotonic() > deadline then
                logger.warn("wificonnect: subprocess timed out after", timeout_s, "s")
                ffiutil.terminateSubProcess(pid)
                closePipe()
                UIManager:scheduleIn(1, collect)
                on_done(false)
            else
                UIManager:scheduleIn(POLL_INTERVAL, check)
            end
        end
        UIManager:scheduleIn(POLL_INTERVAL, check)
    end

    -- Poll check_fn() every 250 ms until it returns something truthy or timeout_s elapses.
    -- Not called back at all if the attempt is cancelled.
    local function pollUntil(check_fn, timeout_s, on_result)
        local my_gen = gen
        local deadline = time.monotonic() + time.s(timeout_s)
        local function tick()
            if gen ~= my_gen then return end
            local res = check_fn()
            if res then
                on_result(res)
            elseif time.monotonic() > deadline then
                on_result(nil)
            else
                UIManager:scheduleIn(POLL_INTERVAL, tick)
            end
        end
        tick()
    end

    -- Run fn(wcli) against wpa_supplicant's control socket (fast, local).
    local function withWpa(fn)
        local wcli, err = WpaClient.new(NetworkMgr.wpa_supplicant.ctrl_interface)
        if not wcli then
            logger.warn("wificonnect: cannot reach wpa_supplicant:", err)
            return nil
        end
        local ok, res = pcall(fn, wcli)
        wcli:close()
        if not ok then
            logger.warn("wificonnect: wpa_supplicant command failed:", res)
            return nil
        end
        return res
    end

    -- Add one KOReader network to wpa_supplicant (in memory only: wpa_supplicant is terminated
    -- when Wi-Fi goes off, and we never write the Kobo OS's config). Returns its id, or nil.
    local function addNetwork(wcli, nw)
        if M.needsPsk(nw) then
            -- PBKDF2, 4096 rounds: done once, then stored like stock does.
            nw.psk = M.toHex(crypto.pbkdf2_hmac_sha1(nw.password, nw.ssid, 4096, 32))
            NetworkMgr:saveNetwork(nw)
        end
        local params = M.networkParams(nw)
        if not params then return nil end
        local id = wcli:addNetwork()
        if not id then return nil end
        for __, kv in ipairs(params) do
            local reply = wcli:setNetwork(id, kv[1], kv[2])
            if reply == nil or reply == "FAIL" then
                wcli:removeNetwork(id)
                return nil
            end
        end
        wcli:enableNetworkByID(id)
        return id
    end

    -- Hand every KOReader-saved network wpa_supplicant doesn't know yet over to it.
    -- Returns how many networks wpa_supplicant now has to try (nil if unreachable).
    local function handOff()
        return withWpa(function(wcli)
            local known = wcli:listNetworks() or {}
            local count = #known
            for __, nw in ipairs(M.pickNetworks(NetworkMgr:getAllSavedNetworks().data, known)) do
                if addNetwork(wcli, nw) then
                    count = count + 1
                    logger.dbg("wificonnect: handed network to wpa_supplicant:", nw.ssid)
                end
            end
            return count
        end)
    end

    -- The network wpa_supplicant has completed association with, if any.
    local function associated()
        return withWpa(function(wcli)
            local nw = wcli:getConnectedNetwork()
            if nw then nw.ssid = M.decodeSSID(nw.ssid) end
            return nw
        end)
    end

    -- Wait for wpa_supplicant to join a network, then DHCP. on_done(ssid) on success;
    -- on failure on_done(nil, "nojoin") (nothing joined) or on_done(nil, "dhcp").
    local function joinAndGetIP(on_done)
        pollUntil(associated, JOIN_TIMEOUT_S, function(nw)
            if not nw then
                logger.dbg("wificonnect: no network joined within", JOIN_TIMEOUT_S, "s")
                return on_done(nil, "nojoin")
            end
            subprocessCall(function() NetworkMgr:obtainIP() end, DHCP_TIMEOUT_S, function(ok)
                if not ok then
                    logger.warn("wificonnect: DHCP failed or timed out on", nw.ssid)
                    return on_done(nil, "dhcp")
                end
                -- Same bookkeeping as stock, so hasLeaseForCurrentNetwork() works (#14790).
                NetworkMgr.lease_ssid = nw.ssid
                on_done(nw.ssid)
            end)
        end)
    end

    -- The stock turnOnWifi runs enable-wifi.sh (about 3.5 s of fixed sleeps on MTK Kobos, plus
    -- module loading) and then reconnects, all on the UI thread. Run it in a child with the
    -- reconnect step stubbed out (the stub only exists in the child), and carry on once the
    -- script is done.
    local orig_turnOnWifi = NetworkMgr.turnOnWifi
    local function bringUp(on_up)
        subprocessCall(function()
            NetworkMgr.reconnectOrShowNetworkMenu = function() end
            orig_turnOnWifi(NetworkMgr, nil, false)
        end, BRINGUP_TIMEOUT_S, function(ok)
            if ok then return on_up() end
            logger.warn("wificonnect: Wi-Fi hardware bring-up failed or timed out")
            report("problem")
            NetworkMgr:_abortWifiConnection()
        end)
    end

    -- Network list (NetworkSetting): tapping a network runs authenticateNetwork + DHCP on the
    -- UI thread (up to about 60 s). NetworkItem is module-local to networksetting.lua, so reach it
    -- as an upvalue of NetworkSetting.init. Patched lazily, right before we first show the list.
    local list_patched = false
    local function patchNetworkList(NetworkSetting)
        if list_patched then return end
        list_patched = true
        local NetworkItem
        for i = 1, 255 do
            local name, value = debug.getupvalue(NetworkSetting.init, i)
            if not name then break end
            if name == "NetworkItem" then
                NetworkItem = value
                break
            end
        end
        if type(NetworkItem) ~= "table" or type(NetworkItem.connect) ~= "function" then
            logger.warn("wificonnect: NetworkItem not found, the network list stays stock")
            return
        end
        local orig_connect = NetworkItem.connect
        function NetworkItem:connect()
            if not enabled() then return orig_connect(self) end
            local connected_item = self.setting_ui:getConnectedItem()
            if connected_item then connected_item:disconnect() end
            start()
            -- The user picked this network: add it with KOReader's credentials (even if the
            -- Kobo OS knows it too) and select it, which disables the others for this session.
            local nw_id = withWpa(function(wcli)
                local id = addNetwork(wcli, self.info)
                if id then wcli:sendCtrlCmd("SELECT_NETWORK " .. id) end
                return id
            end)
            if not nw_id then
                report("problem")
                return
            end
            joinAndGetIP(function(ssid)
                if ssid then
                    self.info.connected = true
                    self.info.wpa_supplicant_id = nw_id
                    self.setting_ui:setConnectedItem(self)
                    -- Same as stock: only a successful connect triggers connect_callback.
                    if self.setting_ui.connect_callback then
                        self.setting_ui.connect_callback()
                    end
                    report("connected", { ssid = ssid })
                else
                    withWpa(function(wcli)
                        wcli:removeNetwork(nw_id)
                        wcli:enableNetworkByID("all") -- undo SELECT_NETWORK
                    end)
                    report("problem")
                    -- The user is looking at the list and expects an answer there.
                    UIManager:show(InfoMessage:new{ text = _("Timed out"), timeout = 3 })
                end
                self:refresh()
            end)
        end
    end

    -- Scan in a subprocess, then show the stock network list.
    local function scanThenShowList(connect_callback)
        local function show(ok, list)
            if not ok or not list then
                report("problem")
                return NetworkMgr:_abortWifiConnection()
            end
            local NetworkSetting = require("ui/widget/networksetting")
            patchNetworkList(NetworkSetting)
            UIManager:show(NetworkSetting:new{
                network_list = list,
                connect_callback = connect_callback,
            })
        end
        local function scan(on_scan)
            subprocessCall(function() return NetworkMgr:getNetworkList() end, SCAN_TIMEOUT_S, on_scan)
        end
        scan(function(ok, list)
            if ok and list and #list == 0 then -- stock rescans once on an empty first scan (#4387)
                return scan(show)
            end
            show(ok, list)
        end)
    end

    -- Everything after bring-up: hand off, wait for a join, DHCP, then finish like stock.
    -- quiet: a background restore (wake/startup) that finds nothing to join isn't a problem,
    -- it just gives up.
    local function connect(complete_callback, interactive, quiet)
        local long_press = NetworkMgr.wifi_toggle_long_press
        NetworkMgr.wifi_toggle_long_press = nil
        local function giveUp(reason)
            if interactive then
                -- Like stock: let the user pick a network; Wi-Fi stays on. Nothing joining
                -- isn't an error, the list is the message; a DHCP failure is.
                report(reason == "dhcp" and "problem" or "choose")
                scanThenShowList(complete_callback)
            else
                report((quiet and reason ~= "dhcp") and "off" or "problem")
                NetworkMgr:_abortWifiConnection()
            end
        end
        if handOff() == 0 then
            -- Nothing to try: skip the join wait, like stock does in this case.
            logger.dbg("wificonnect: wpa_supplicant has no networks to try")
            return giveUp("nojoin")
        end
        joinAndGetIP(function(ssid, reason)
            if not ssid then
                return giveUp(reason)
            end
            if complete_callback then complete_callback() end
            report("connected", { ssid = ssid })
            if long_press then scanThenShowList() end -- the user asked for the list
        end)
    end

    -- Entry points. Contract (frontend/ui/network/manager.lua): returning nil from
    -- turnOnWifi means "pending"; enableWifi only aborts on a literal false, so on failure
    -- we call _abortWifiConnection() ourselves. complete_callback schedules the connectivity
    -- check that broadcasts NetworkConnected.
    function NetworkMgr:turnOnWifi(complete_callback, interactive)
        if not enabled() then
            return orig_turnOnWifi(self, complete_callback, interactive)
        end
        start()
        bringUp(function() connect(complete_callback, interactive) end)
        return nil
    end

    local orig_reconnect = NetworkMgr.reconnectOrShowNetworkMenu
    function NetworkMgr:reconnectOrShowNetworkMenu(complete_callback, interactive)
        if not enabled() then
            return orig_reconnect(self, complete_callback, interactive)
        end
        start()
        connect(complete_callback, interactive)
        return nil
    end

    -- On wake and at startup (auto_restore_wifi). The callers schedule their own
    -- connectivity check, which broadcasts NetworkConnected once we're done.
    local orig_restore = NetworkMgr.restoreWifiAsync
    function NetworkMgr:restoreWifiAsync()
        if not enabled() then
            return orig_restore(self)
        end
        start()
        bringUp(function() connect(nil, false, true) end)
    end

    logger.info("WifiIndicator: non-blocking Wi-Fi connect engine installed")
    return true
end

return M
