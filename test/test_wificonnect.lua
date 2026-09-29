-- Unit tests for the pure logic in wificonnect.lua (no KOReader needed).
-- Run from the repo root:
--   luajit test/test_wificonnect.lua

local M = assert(loadfile(arg[1] or "wificonnect.lua"))()

local failures = 0
local function check(cond, label)
    print(string.format("[%s] %s", cond and "PASS" or "FAIL", label))
    if not cond then failures = failures + 1 end
end

local function sameParams(got, want)
    if got == nil or #got ~= #want then return false end
    for i, kv in ipairs(want) do
        if got[i][1] ~= kv[1] or got[i][2] ~= kv[2] then return false end
    end
    return true
end

-- ---------------------------------------------------------- decodeSSID --
check(M.decodeSSID("Home") == "Home", "decodeSSID: plain SSID unchanged")
check(M.decodeSSID("Caf\\xc3\\xa9") == "Café", "decodeSSID: \\xNN bytes decoded (UTF-8)")
check(M.decodeSSID("a\\\\b") == "a\\b", "decodeSSID: escaped backslash")
check(M.decodeSSID("a\\x5cb") == "a\\b", "decodeSSID: \\x5c is a literal backslash")

-- --------------------------------------------------------------- toHex --
check(M.toHex("Home") == "486f6d65", "toHex: ASCII")
check(M.toHex("é") == "c3a9", "toHex: UTF-8 bytes")
check(M.toHex("") == "", "toHex: empty string")

-- ------------------------------------------------------------ needsPsk --
check(M.needsPsk({ ssid = "a", password = "secret" }) == true, "needsPsk: password, no psk")
check(M.needsPsk({ ssid = "a", password = "secret", psk = "ab" }) == false, "needsPsk: psk already known")
check(M.needsPsk({ ssid = "a", password = "" }) == false, "needsPsk: open network")
check(M.needsPsk({ ssid = "a" }) == false, "needsPsk: no password")

-- ------------------------------------------------------- networkParams --
check(sameParams(M.networkParams({ ssid = "Home", password = "x", psk = "abcd" }),
    { { "ssid", "486f6d65" }, { "psk", "abcd" } }), "networkParams: WPA network uses the stored psk")
check(sameParams(M.networkParams({ ssid = "Cafe", password = "" }),
    { { "ssid", "43616665" }, { "key_mgmt", "NONE" } }), "networkParams: open network")
check(M.networkParams({ ssid = "Home", password = "x" }) == nil, "networkParams: nil until psk is derived")
check(M.networkParams({ ssid = "", password = "" }) == nil, "networkParams: empty SSID rejected")
check(M.networkParams({ password = "" }) == nil, "networkParams: missing SSID rejected")
check(M.networkParams(nil) == nil, "networkParams: nil entry rejected")

-- -------------------------------------------------------- pickNetworks --
local saved = {
    Home = { ssid = "Home", password = "x", psk = "aa" },
    ["Café"] = { ssid = "Café", password = "" },
    Office = { ssid = "Office", password = "y" },
    Broken = { ssid = "Broken" }, -- no password, no psk
    Kobo = { ssid = "Kobo", password = "z", psk = "bb" },
}
local known = {
    { id = "0", ssid = "Kobo" },
    { id = "1", ssid = "Caf\\xc3\\xa9" }, -- escaped form, as LIST_NETWORKS reports it
}
local picked = M.pickNetworks(saved, known)
local names = {}
for i, nw in ipairs(picked) do names[i] = nw.ssid end
check(table.concat(names, ",") == "Home,Office",
    "pickNetworks: skips known (incl. escaped SSIDs) and unusable entries, sorted by SSID")
check(picked[1] == saved.Home, "pickNetworks: returns the saved entries themselves (so psk can be stored)")
check(#M.pickNetworks(saved, nil) == 4, "pickNetworks: nil known list -> every usable saved network")
check(#M.pickNetworks(nil, known) == 0, "pickNetworks: nil saved list -> nothing")

print(failures == 0 and "ALL TESTS PASSED" or (failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
