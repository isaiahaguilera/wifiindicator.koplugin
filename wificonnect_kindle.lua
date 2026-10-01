--[[--
Kindle backend for wificonnect.lua, loaded only on Kindles with KOReader's lipc bindings.

On a Kindle, turning Wi-Fi on is a fast lipc call, and Amazon's wifid joins networks and runs
DHCP by itself. KOReader's saved networks are wifid's own profiles, so they already reconnect
after sleep. The one thing that freezes the screen is the scan: KOReader's
kindleScanThenGetResults waits on the UI thread for up to 20 s (40 s with the empty-list
rescan). So this only replaces reconnectOrShowNetworkMenu: scan in a subprocess, then do what
stock does.
]]--

-- How long to wait for wifid to connect, like KOReader's own connectivity check.
local CONNECT_TIMEOUT_S = 45

return function(core)
    local NetworkMgr = core.NetworkMgr
    local report, start, enabled = core.report, core.start, core.enabled

    local orig_reconnect = NetworkMgr.reconnectOrShowNetworkMenu
    -- Stock Kindle turnOnWifi enables Wi-Fi (fast) and then calls this.
    function NetworkMgr:reconnectOrShowNetworkMenu(complete_callback, interactive)
        if not enabled() then
            return orig_reconnect(self, complete_callback, interactive)
        end
        local long_press = self.wifi_toggle_long_press
        self.wifi_toggle_long_press = nil
        start()
        core.scanNetworks(function(ok, list)
            if not ok or not list then
                report("problem")
                return self:_abortWifiConnection()
            end
            table.sort(list, function(a, b) return (a.signal_quality or 0) > (b.signal_quality or 0) end)
            -- Like stock: wifid may already be on a known network. Otherwise ask it for the
            -- strongest saved one in range (one fast lipc call).
            local target
            for __, nw in ipairs(list) do
                if nw.connected then target = nw break end
            end
            if not target then
                for __, nw in ipairs(list) do
                    if nw.password then target = nw break end
                end
                if target then self:authenticateNetwork(target) end
            end
            if not target then
                -- No saved network in range: the list is the answer if the user asked.
                if interactive then
                    report("choose")
                    return core.showList(list, complete_callback)
                end
                report("problem")
                return self:_abortWifiConnection()
            end
            core.pollUntil(function() return self:isConnected() end, CONNECT_TIMEOUT_S, function(connected)
                if not connected then
                    report("problem")
                    if interactive then
                        return core.showList(list, complete_callback)
                    end
                    return self:_abortWifiConnection()
                end
                target.connected = true
                -- Same bookkeeping as stock, so hasLeaseForCurrentNetwork() works (#14790).
                self.lease_ssid = target.ssid
                if complete_callback then complete_callback() end
                report("connected", { ssid = target.ssid })
                if long_press then core.showList(list) end -- the user asked for the list
            end)
        end)
        return nil -- pending: we finish (or abort) ourselves
    end
end
