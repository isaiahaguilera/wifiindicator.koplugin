-- Desktop simulation of the wificonnect.lua engine: fake KOReader, fake wpa_supplicant,
-- fake subprocesses (run inline, with fork isolation emulated), and a virtual clock.
-- It checks the engine's flow and bookkeeping, not real hardware timing.
-- Run from the repo root:
--   luajit test/test_engine.lua

-- KOReader's LuaJIT is built with Lua 5.2 compat (table.pack); a stock desktop LuaJIT isn't.
table.pack = table.pack or function(...) return { n = select("#", ...), ... } end

-- ------------------------------------------------------------ virtual clock --
local now = 0
local queue = {}
local UIManager = { shown = {} }
function UIManager:scheduleIn(s, fn, ...)
    table.insert(queue, { t = now + s, fn = fn, args = { n = select("#", ...), ... } })
end
function UIManager:unschedule(fn)
    for i = #queue, 1, -1 do
        if queue[i].fn == fn then table.remove(queue, i) end
    end
end
function UIManager:show(w) table.insert(self.shown, w) end
function UIManager:close(w) self.closed = self.closed or {}; table.insert(self.closed, w) end
local function run(max_s)
    local stop = now + (max_s or 120)
    while #queue > 0 do
        table.sort(queue, function(a, b) return a.t < b.t end)
        local ev = table.remove(queue, 1)
        if ev.t > stop then table.insert(queue, ev) break end
        now = ev.t
        ev.fn(unpack(ev.args, 1, ev.args.n))
    end
end

-- ----------------------------------------------------------- fake wpa_supplicant --
local wpa -- reset per scenario
local function resetWpa(in_range)
    wpa = {
        networks = {}, -- id -> { ssid_hex, psk, key_mgmt, enabled, from_kobo }
        next_id = 0,
        in_range = in_range or {}, -- ssid -> true
        join_after = 1.0, -- seconds after an eligible network is enabled
        eligible_since = nil,
        commands = {},
    }
end
local function hexToStr(h) return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end
local function addKoboNetwork(ssid)
    local id = tostring(wpa.next_id)
    wpa.next_id = wpa.next_id + 1
    wpa.networks[id] = { ssid = ssid, enabled = true, from_kobo = true }
end
local function joinable()
    for id, nw in pairs(wpa.networks) do
        local ssid = nw.ssid or (nw.ssid_hex and hexToStr(nw.ssid_hex))
        if nw.enabled and ssid and wpa.in_range[ssid] and (nw.psk or nw.key_mgmt or nw.from_kobo) then
            return id, ssid
        end
    end
end

local WpaClient = {}
WpaClient.__index = WpaClient
function WpaClient.new() return setmetatable({}, WpaClient) end
function WpaClient:close() end
function WpaClient:listNetworks()
    local out = {}
    for id, nw in pairs(wpa.networks) do
        local ssid = nw.ssid or hexToStr(nw.ssid_hex or "")
        -- LIST_NETWORKS escapes non-ASCII bytes as \xNN
        ssid = ssid:gsub("[\128-\255]", function(c) return string.format("\\x%02x", c:byte()) end)
        table.insert(out, { id = id, ssid = ssid })
    end
    return out
end
function WpaClient:addNetwork()
    local id = tostring(wpa.next_id)
    wpa.next_id = wpa.next_id + 1
    wpa.networks[id] = { enabled = false }
    table.insert(wpa.commands, "ADD " .. id)
    return id
end
function WpaClient:setNetwork(id, key, value)
    local nw = wpa.networks[id]
    if key == "ssid" then nw.ssid_hex = value else nw[key] = value end
    return "OK"
end
function WpaClient:enableNetworkByID(id)
    table.insert(wpa.commands, "ENABLE " .. id)
    for nid, nw in pairs(wpa.networks) do
        if id == "all" or nid == id then nw.enabled = true end
    end
    return "OK"
end
function WpaClient:removeNetwork(id)
    table.insert(wpa.commands, "REMOVE " .. id)
    wpa.networks[id] = nil
end
function WpaClient:sendCtrlCmd(cmd)
    table.insert(wpa.commands, cmd)
    local id = cmd:match("^SELECT_NETWORK (%S+)$")
    if id then
        for nid, nw in pairs(wpa.networks) do nw.enabled = (nid == id) end
    end
    return "OK"
end
function WpaClient:getConnectedNetwork()
    local id, ssid = joinable()
    if not id then
        wpa.eligible_since = nil
        return nil, "SCANNING"
    end
    wpa.eligible_since = wpa.eligible_since or now
    if now - wpa.eligible_since >= wpa.join_after then
        return { id = id, ssid = ssid }
    end
    return nil, "ASSOCIATING"
end

-- --------------------------------------------------------------- fake KOReader --
local settings = {}
_G.G_reader_settings = {
    nilOrTrue = function(_, key)
        if settings[key] == nil then return true end
        return settings[key]
    end,
}

local calls
local saved_data
local NetworkMgr = { wpa_supplicant = { ctrl_interface = "/fake" } }
function NetworkMgr:turnOnWifi(complete_callback, interactive) -- the stock Kobo one
    table.insert(calls, "stock turnOnWifi")
    return self:reconnectOrShowNetworkMenu(complete_callback, interactive)
end
function NetworkMgr:reconnectOrShowNetworkMenu() table.insert(calls, "stock reconnect") end
function NetworkMgr:restoreWifiAsync() table.insert(calls, "stock restore") end
function NetworkMgr:disableWifi() table.insert(calls, "disableWifi") end
function NetworkMgr:_abortWifiConnection() table.insert(calls, "abort") end
function NetworkMgr:getAllSavedNetworks() return { data = saved_data } end
function NetworkMgr:saveNetwork(nw) table.insert(calls, "save " .. nw.ssid) end
function NetworkMgr:obtainIP() table.insert(calls, "obtainIP") end
local wifi_on = false
function NetworkMgr:isWifiOn() return wifi_on end
function NetworkMgr:toggleWifiOn(cb, long_press, interactive)
    table.insert(calls, "toggleWifiOn " .. tostring(long_press) .. " " .. tostring(interactive))
end
function NetworkMgr:scheduleConnectivityCheck() table.insert(calls, "connectivity check") end
function NetworkMgr:unscheduleConnectivityCheck() end
function NetworkMgr:getNetworkList()
    local list = {}
    for ssid in pairs(wpa.in_range) do table.insert(list, { ssid = ssid, signal_quality = 50 }) end
    return list
end

-- Fake subprocesses: run the task inline, but restore NetworkMgr afterwards like a fork would.
-- fail_spawn_at = n makes the n-th spawn of a scenario fail (on_done(false)).
local fd_data = {}
local next_pid = 100
local fail_spawn_at, spawn_count = nil, 0
local ffiutil = {
    runInSubProcess = function(fn)
        spawn_count = spawn_count + 1
        if fail_spawn_at == spawn_count then return nil end
        next_pid = next_pid + 1
        local fd = next_pid
        local snapshot = {}
        for k, v in pairs(NetworkMgr) do snapshot[k] = v end
        fn(next_pid, fd)
        for k in pairs(NetworkMgr) do NetworkMgr[k] = nil end
        for k, v in pairs(snapshot) do NetworkMgr[k] = v end
        return next_pid, fd
    end,
    writeToFD = function(fd, str) fd_data[fd] = (fd_data[fd] or "") .. str end,
    getNonBlockingReadSize = function(fd) return fd_data[fd] and #fd_data[fd] or 0 end,
    isSubProcessDone = function() return true end,
    terminateSubProcess = function() end,
}
local fake_ffi = {
    C = {
        fcntl = function() end,
        close = function() end,
        read = function(fd, buf, n)
            buf.data = fd_data[fd]:sub(1, n)
            fd_data[fd] = fd_data[fd]:sub(n + 1)
            return #buf.data
        end,
    },
    new = function() return {} end,
    string = function(buf) return buf.data end,
    cast = function(_, v) return v end,
}

-- Network list widget with a module-local NetworkItem, like networksetting.lua.
local NetworkItem = {}
NetworkItem.__index = NetworkItem
function NetworkItem:connect() table.insert(calls, "stock item connect") end
function NetworkItem:disconnect() table.insert(calls, "item disconnect") end
function NetworkItem:refresh() end
local NetworkSetting = {}
function NetworkSetting.init(self)
    self.items = {}
    for _, nw in ipairs(self.network_list) do
        table.insert(self.items, setmetatable({ info = nw, setting_ui = self }, NetworkItem))
        if nw.connected then self.connected_item = self.items[#self.items] end
    end
    -- Like the real init: with a connect_callback and an already-connected network, it assumes
    -- a reconnect "missed it", re-runs DHCP on the UI thread and closes the list (legacy path).
    if self.connect_callback and self.connected_item then
        table.insert(calls, "legacy re-DHCP")
    end
end
function NetworkSetting:new(o)
    o = setmetatable(o, { __index = self })
    o:init()
    return o
end
function NetworkSetting:getConnectedItem() return self.connected_item end
function NetworkSetting:setConnectedItem(item) self.connected_item = item end

package.loaded["ffi"] = fake_ffi
package.preload["ui/network/manager"] = function() return NetworkMgr end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, o) o.is_info = true return o end }
end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["lj-wpaclient/wpaclient"] = function() return WpaClient end
package.preload["ffi/crypto"] = function()
    return { pbkdf2_hmac_sha1 = function(pwd, ssid) return "K" .. #pwd .. #ssid end }
end
package.preload["ffi/util"] = function() return ffiutil end
package.preload["logger"] = function()
    return { dbg = function() end, info = function() end, warn = function() end }
end
package.preload["ui/time"] = function()
    return { monotonic = function() return now end, s = function(s) return s end }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ui/widget/networksetting"] = function() return NetworkSetting end

-- ------------------------------------------------------------------ harness --
local M = assert(loadfile("wificonnect.lua"))()
local statuses
M.on_status = function(state) table.insert(statuses, state) end
local installed = M.install()

local failures = 0
local function check(cond, label)
    print(string.format("[%s] %s", cond and "PASS" or "FAIL", label))
    if not cond then failures = failures + 1 end
end
local function has(list, item)
    for _, v in ipairs(list) do if v == item then return true end end
    return false
end
local function scenario(opts)
    now, queue, calls, statuses, spawn_count = 0, {}, {}, {}, 0
    UIManager.shown = {}
    settings = {}
    resetWpa(opts.in_range)
    for _, ssid in ipairs(opts.kobo or {}) do addKoboNetwork(ssid) end
    saved_data = opts.saved or {}
    NetworkMgr.lease_ssid = nil
    NetworkMgr.wifi_toggle_long_press = opts.long_press
end

check(installed and M.installed, "install: engine installs on a wpa_supplicant device")
check(M.install() == true, "install: second call is a no-op that still reports installed")

-- A: menu toggle, network known only to KOReader
scenario{ in_range = { Home = true }, saved = { Home = { ssid = "Home", password = "secret" } } }
local cb = 0
local ret = NetworkMgr:turnOnWifi(function() cb = cb + 1 end, true)
check(ret == nil, "A: turnOnWifi returns nil (pending)")
check(statuses[1] == "connecting" and #statuses == 1, "A: reports connecting right away, before any wait")
run()
check(has(calls, "stock turnOnWifi") and not has(calls, "stock reconnect"),
    "A: bring-up runs the stock enable step with reconnect stubbed (in the child)")
check(NetworkMgr.reconnectOrShowNetworkMenu ~= nil and has(calls, "save Home"),
    "A: psk derived and saved; parent's NetworkMgr untouched by the child's stub")
check(cb == 1 and statuses[#statuses] == "connected", "A: joins, runs complete_callback once, reports connected")
check(NetworkMgr.lease_ssid == "Home" and has(calls, "obtainIP"), "A: DHCP ran and lease_ssid is recorded")
check(#UIManager.shown == 0, "A: no popups shown")

-- B: network known to the Kobo OS is not added again
scenario{ in_range = { Office = true }, kobo = { "Office" }, saved = { Office = { ssid = "Office", password = "", } } }
NetworkMgr:turnOnWifi(nil, true)
run()
check(not has(wpa.commands, "ADD 1") and statuses[#statuses] == "connected",
    "B: Kobo-known SSID is not duplicated, still connects")

-- E: nothing in range, non-interactive -> abort
scenario{ in_range = {}, saved = { Home = { ssid = "Home", password = "x", psk = "ab" } } }
cb = 0
NetworkMgr:turnOnWifi(function() cb = cb + 1 end, false)
run()
check(cb == 0 and has(calls, "abort") and statuses[#statuses] == "problem" and M.state == "problem",
    "E: no join for an action that needed the network -> problem, _abortWifiConnection, no callback")
check(now >= 15 and now <= 16, "E: gives up after about 15 s of waiting for a join")

-- E1: saved network not in range, interactive -> the list, reported as "choose", not a problem
scenario{ in_range = {}, saved = { Home = { ssid = "Home", password = "x", psk = "ab" } } }
NetworkMgr.getNetworkList = function()
    return { -- a dual-band neighbor: one entry per radio
        { ssid = "Neighbor", bssid = "n:5", signal_quality = 40 },
        { ssid = "Neighbor", bssid = "n:2", signal_quality = 55 },
    }
end
NetworkMgr:turnOnWifi(nil, true)
run()
check(statuses[#statuses] == "choose" and not has(statuses, "problem") and UIManager.shown[1],
    "E1: interactive, nothing joins -> 'choose' and the network list, no problem icon")
check(#UIManager.shown[1].network_list == 1 and UIManager.shown[1].network_list[1].bssid == "n:2",
    "E1: the list shows a dual-band network once (its strongest radio)")

-- E2: nothing to try at all, interactive -> skip the wait, straight to the list
scenario{ in_range = {}, saved = {} }
NetworkMgr.getNetworkList = function() return {} end
NetworkMgr:turnOnWifi(nil, true)
run()
check(not has(calls, "abort") and UIManager.shown[1] and #UIManager.shown[1].network_list == 0,
    "E2: interactive failure with an empty scan (after one rescan) shows an empty list, like stock")
check(now < 5, "E2: nothing to try -> no 15 s join wait")
scenario{ in_range = {}, saved = {} }
wpa.in_range = {}
NetworkMgr.getNetworkList = function() return { { ssid = "Neighbor", signal_quality = 40 } } end
NetworkMgr:turnOnWifi(nil, true)
run()
local list = UIManager.shown[1]
check(list and list.network_list and list.network_list[1].ssid == "Neighbor",
    "E2: interactive failure shows the network list")
check(not has(calls, "abort"), "E2: Wi-Fi is not torn down while the list is up")

-- G: turning Wi-Fi off mid-connect cancels everything
scenario{ in_range = { Home = true }, saved = { Home = { ssid = "Home", password = "x", psk = "ab" } } }
cb = 0
NetworkMgr:turnOnWifi(function() cb = cb + 1 end, true)
NetworkMgr:disableWifi()
run()
check(cb == 0 and #statuses == 1 and not has(calls, "obtainIP"),
    "G: disableWifi cancels the attempt: no callback, no DHCP, no further status")
check(M.state == "idle", "G: a cancelled attempt no longer reads as connecting")

-- C: wake from sleep restores KOReader-only networks
scenario{ in_range = { Home = true }, saved = { Home = { ssid = "Home", password = "x", psk = "ab" } } }
NetworkMgr:restoreWifiAsync()
run()
check(not has(calls, "stock restore") and statuses[#statuses] == "connected" and NetworkMgr.lease_ssid == "Home",
    "C: restoreWifiAsync hands off KOReader networks and connects")

-- C2: wake away from home: quietly gives up, no problem icon
scenario{ in_range = {}, saved = { Home = { ssid = "Home", password = "x", psk = "ab" } } }
NetworkMgr:restoreWifiAsync()
run()
check(statuses[#statuses] == "off" and not has(statuses, "problem") and has(calls, "abort"),
    "C2: restore with no known network nearby -> quietly 'off', Wi-Fi torn down")

-- D: joins, but DHCP never completes -> that's a real problem, even for the quiet restore
scenario{ in_range = { Home = true }, saved = { Home = { ssid = "Home", password = "x", psk = "ab" } } }
fail_spawn_at = 2 -- 1st subprocess: bring-up, 2nd: DHCP
NetworkMgr:restoreWifiAsync()
run()
fail_spawn_at = nil
check(statuses[#statuses] == "problem" and has(calls, "abort") and NetworkMgr.lease_ssid == nil,
    "D: DHCP failure -> problem, even on a background restore")

-- Kill switch
scenario{ in_range = { Home = true }, saved = {} }
settings.wifiindicator_nonblocking_wifi = false
NetworkMgr:turnOnWifi(nil, true)
NetworkMgr:restoreWifiAsync()
check(has(calls, "stock turnOnWifi") and has(calls, "stock reconnect") and has(calls, "stock restore")
    and #statuses == 0, "kill switch: setting off -> pure stock behavior")

-- Long press: list shown after a successful connect
scenario{ in_range = { Home = true }, saved = { Home = { ssid = "Home", password = "x", psk = "ab" } }, long_press = true }
NetworkMgr.getNetworkList = function() return { { ssid = "Home", signal_quality = 90 } } end
NetworkMgr:turnOnWifi(nil, true)
run()
check(statuses[#statuses] == "connected" and UIManager.shown[1] and UIManager.shown[1].network_list,
    "long press: connects, then shows the network list")
check(NetworkMgr.wifi_toggle_long_press == nil, "long press: flag cleared")

-- I/J: network list, tapping a network (list was shown above, so NetworkItem is patched)
local ui = UIManager.shown[1]
scenario{ in_range = { Cafe = true }, kobo = { "Cafe" } }
local item = setmetatable({ info = { ssid = "Cafe", password = "new-pass" }, setting_ui = ui }, NetworkItem)
local list_cb = 0
ui.connect_callback = function() list_cb = list_cb + 1 end
item:connect()
check(has(calls, "item disconnect") == false and statuses[1] == "connecting",
    "I: tap reports connecting without blocking")
run()
check(has(wpa.commands, "SELECT_NETWORK 1"), "I: adds the tapped network with KOReader's credentials and selects it")
check(item.info.connected and ui:getConnectedItem() == item and list_cb == 1 and statuses[#statuses] == "connected",
    "I: success marks the item connected and runs connect_callback")

scenario{ in_range = {} }
local item2 = setmetatable({ info = { ssid = "Far", password = "x", psk = "ab" }, setting_ui = ui }, NetworkItem)
item2:connect()
run()
check(has(calls, "item disconnect"), "J: disconnects the previously connected item first, like stock")
check(has(wpa.commands, "REMOVE 0") and has(wpa.commands, "ENABLE all"),
    "J: failure removes the network and undoes SELECT_NETWORK")
check(statuses[#statuses] == "problem" and UIManager.shown[#UIManager.shown].text == "Timed out",
    "J: failure reports a problem and tells the user in the list")

-- L: "Show network list" menu action
scenario{ in_range = {} }
UIManager.closed = {}
wifi_on = true
NetworkMgr.getNetworkList = function() -- already connected to Home
    return { { ssid = "Home", bssid = "h:5", signal_quality = 70, connected = true },
             { ssid = "Home", bssid = "h:2", signal_quality = 50 } }
end
M.showNetworkList()
local looking = UIManager.shown[1]
check(looking and looking.text == "Looking for networks…" and looking.timeout,
    "L: Wi-Fi on -> a 'Looking for networks…' note right away (with a safety timeout)")
run()
local shown_list = UIManager.shown[2]
check(shown_list and shown_list.network_list and #shown_list.network_list == 1,
    "L: fresh scan, then the list (duplicates merged)")
check(has(UIManager.closed, looking), "L: the note closes when the list appears")
check(not has(calls, "legacy re-DHCP") and not has(UIManager.closed, shown_list),
    "L: already connected -> no 'Obtaining IP address…' re-DHCP, and the list stays open")
shown_list.connect_callback()
check(has(calls, "connectivity check") and not has(calls, "abort"),
    "L: joining from that list lets KOReader confirm and broadcast the connection")

scenario{ in_range = {} }
UIManager.closed = {}
fail_spawn_at = 1
M.showNetworkList()
run()
fail_spawn_at = nil
check(statuses[#statuses] == "problem" and not has(calls, "abort") and has(UIManager.closed, UIManager.shown[1]),
    "L: scan failure -> problem icon, note closed, Wi-Fi left as it was")

scenario{ in_range = {} }
wifi_on = false
M.showNetworkList()
check(has(calls, "toggleWifiOn true true") and #UIManager.shown == 0,
    "L: Wi-Fi off -> turns it on like a long-press (connect, then the list)")

print(failures == 0 and "ALL TESTS PASSED" or (failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
