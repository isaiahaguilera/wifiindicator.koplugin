--[[--
Non-blocking Wi-Fi connect engine for Kobo (wpa_supplicant).

Stock KOReader connects on the UI thread and drives wpa_supplicant itself: scan, then try
KOReader's saved networks one at a time (up to 30 s each), then DHCP. wpa_supplicant is
started with the Kobo OS's own config, so it already joins the Kobo OS's networks by itself,
while networks saved only in KOReader never come back on wake (restore-wifi-async.sh only
waits for wpa_supplicant).

This engine instead hands every KOReader-saved network to wpa_supplicant as soon as it is up
and lets wpa_supplicant pick. See docs/plan-wpa-handoff.md.

This top part is pure logic with no KOReader dependencies, so test/test_wificonnect.lua can
exercise it on a desktop LuaJIT.
]]--

local M = {
    installed = false,
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

return M
