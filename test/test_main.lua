-- Test harness for wifiindicator.koplugin: stubs the KOReader modules and loads the real plugin.
-- Run from the repo root (main.lua's require("wificonnect") resolves via ./?.lua):
--   luajit test/test_main.lua main.lua

local plugin_path = arg[1] or "main.lua"

-- ---------------------------------------------------------------- stubs --
local shown = {}
local broadcasts = {}
local wifi = { on = false, connected = false }

local UIManager = {
    unschedule = function() end,
    scheduleIn = function() end,
    close = function() end,
    setDirty = function() end,
    broadcastEvent = function(self, ev) table.insert(broadcasts, ev.name) end,
    isWidgetShown = function(self, w) return w.is_shown == true end,
}
UIManager.show = function(self, widget, ...)
    table.insert(shown, widget)
end

local settings_data = {
    wifiindicator_show_icon = false, -- keep corner-toast code path out of these tests
}
_G.G_reader_settings = {
    nilOrTrue = function(self, key)
        local v = settings_data[key]
        if v == nil then return true end
        return v
    end,
    flipNilOrTrue = function() end,
}

local identity_gettext = setmetatable({}, { __call = function(_, s) return s end })

local FakeTouchMenu = {}
FakeTouchMenu.init = function(menu)
    menu.show_parent = menu
    menu.time_info = { name = "time_info" }
    menu.device_info = {
        menu.time_info,
        resetLayout = function() end,
    }
end
FakeTouchMenu.updateItems = function(menu) end

package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 0 } end
package.preload["device"] = function()
    return {
        screen = { scaleBySize = function(_, n) return n end },
        isKobo = function() return false end,
        isKindle = function() return false end,
    }
end
package.preload["ui/widget/container/framecontainer"] = function()
    return { new = function(self, t) return t end }
end
package.preload["ui/widget/iconwidget"] = function()
    return { new = function(self, t) return t end }
end
package.preload["ui/size"] = function()
    return { padding = { small = 2 }, span = { horizontal_default = 4 } }
end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(self, t) return t end }
end
package.preload["logger"] = function()
    return { dbg = function() end, warn = function() end, info = function() end }
end
package.preload["gettext"] = function() return identity_gettext end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
package.preload["ui/widget/iconbutton"] = function()
    local IconButton = {}
    IconButton.__index = IconButton
    IconButton.new = function(_, o)
        o = o or {}
        o.is_icon_button = true
        return setmetatable(o, IconButton)
    end
    function IconButton:setIcon(icon)
        if icon ~= self.icon then self.icon = icon end
    end
    return IconButton
end
package.preload["ui/network/manager"] = function()
    -- No wpa_supplicant field: wificonnect.install() stays a no-op under this harness.
    return {
        isWifiOn = function() return wifi.on end,
        isConnected = function() return wifi.connected end,
    }
end
package.preload["ui/widget/touchmenu"] = function() return FakeTouchMenu end

-- ------------------------------------------------------------- helpers --
local failures = 0
local function check(cond, label)
    print(string.format("[%s] %s", cond and "PASS" or "FAIL", label))
    if not cond then failures = failures + 1 end
end

local function isSuppressed(text)
    shown = {}
    UIManager:show({ text = text })
    return #shown == 0
end

local function newMenu()
    local menu = {}
    FakeTouchMenu.init(menu)
    return menu
end

local WifiIndicator = assert(loadfile(plugin_path))()

-- --------------------------------------- popup suppression (regression) --
for __, msg in ipairs({
    "Scanning for networks…",
    "Connection failed",
    "Unable to communicate with the Wi-Fi backend",
    "Scanning for Wi-Fi networks timed out",
    "Error connecting to the network",
    "Connecting to network MyHomeWifi…",
    "Turning on Wi-Fi…",
    "You can now retry the action that required network access",
}) do
    check(isSuppressed(msg), "suppressed: " .. msg)
end
check(not isSuppressed("Book saved"), "passed through: Book saved")
check(not isSuppressed("Connection failed, but with extra text"),
    "passed through: Connection failed, but with extra text")
shown = {}
UIManager:show({ name = "no text" })
check(#shown == 1, "passed through: widget without text")

-- ------------------------------------------------- menu icon: injection --
wifi.on, wifi.connected = true, true
local menu = newMenu()
check(menu.device_info[1] ~= nil and menu.device_info[1].is_icon_button == true,
    "menu icon: IconButton injected at head of device_info")
check(menu.device_info[2] == menu.time_info,
    "menu icon: time_info right after the icon (the icon's padding is the gap)")
local btn = menu.device_info[1]
check(btn.width == 20 and btn.padding_top == 10 and btn.padding_bottom == 10
    and btn.padding_left == 10 and btn.padding_right == 10,
    "menu icon: 20 px icon padded to a 40 px tap target (the footer's up-button size)")
check(menu._wifiindicator_icon == menu.device_info[1],
    "menu icon: icon reachable as menu._wifiindicator_icon")
check(menu.device_info[1].icon == "wifi.open.100",
    "menu icon: connected state at build time")

settings_data.wifiindicator_menu_icon = false
local menu_off = newMenu()
check(menu_off.device_info[1] == menu_off.time_info,
    "menu icon: setting off -> no injection")
settings_data.wifiindicator_menu_icon = nil

assert(loadfile(plugin_path))() -- second plugin instance (FileManager + ReaderUI)
local menu2 = newMenu()
local icon_count = 0
for __, w in ipairs(menu2.device_info) do
    if w.is_icon_button then icon_count = icon_count + 1 end
end
check(icon_count == 1, "menu icon: double plugin load still injects exactly one icon")

-- ---------------------------------------------- menu icon: state refresh --
local wificonnect = require("wificonnect") -- the same module table main.lua wired up
wifi.on, wifi.connected = true, true
local menu_state = newMenu()
wifi.on, wifi.connected = true, false
FakeTouchMenu.updateItems(menu_state)
check(menu_state._wifiindicator_icon.icon == "wifi.open.25",
    "menu icon: on-but-disconnected -> wifi.open.25 (dot only) after updateItems")
wifi.on, wifi.connected = false, false
FakeTouchMenu.updateItems(menu_state)
check(menu_state._wifiindicator_icon.icon == "wifi.open.0",
    "menu icon: off -> wifi.open.0 after updateItems")
wifi.on, wifi.connected = true, true
FakeTouchMenu.updateItems(menu_state)
check(menu_state._wifiindicator_icon.icon == "wifi.open.100",
    "menu icon: connected -> wifi.open.100 after updateItems")

wificonnect.state = "connecting"
wifi.on, wifi.connected = false, false -- radio still off during bring-up
FakeTouchMenu.updateItems(menu_state)
check(menu_state._wifiindicator_icon.icon == "wifi.open.50",
    "menu icon: engine connecting -> wifi.open.50, even before the radio is up")
wificonnect.state = "problem"
wifi.on, wifi.connected = true, false
FakeTouchMenu.updateItems(menu_state)
check(menu_state._wifiindicator_icon.icon == "notice-warning",
    "menu icon: engine problem while on and not connected -> warning")
wifi.on, wifi.connected = false, false
FakeTouchMenu.updateItems(menu_state)
check(menu_state._wifiindicator_icon.icon == "wifi.open.0",
    "menu icon: a past problem doesn't linger once Wi-Fi is off")
wificonnect.state = nil

settings_data.wifiindicator_menu_icon = false
local menu_state_off = newMenu()
local ok_no_icon = pcall(FakeTouchMenu.updateItems, menu_state_off)
check(ok_no_icon, "menu icon: updateItems is a no-op without injected icon")
settings_data.wifiindicator_menu_icon = nil

-- ------------------------------------------------ menu icon: live refresh --
local dirty = 0
UIManager.setDirty = function() dirty = dirty + 1 end
wifi.on, wifi.connected = false, false
local live = newMenu()
live.is_shown = true
wificonnect.state = "connecting" -- the engine reports the state before notifying
wificonnect.on_status("connecting")
check(live._wifiindicator_icon.icon == "wifi.open.50" and dirty == 1,
    "menu icon: follows a status change while the menu is open")
wifi.on, wifi.connected = true, true
wificonnect.state = "connected"
wificonnect.on_status("connected")
check(live._wifiindicator_icon.icon == "wifi.open.100" and dirty == 2,
    "menu icon: switches to connected without reopening the menu")
wificonnect.on_status("connected")
check(dirty == 2, "menu icon: unchanged state -> no extra redraw")
live.is_shown = false
wifi.on, wifi.connected = false, false
WifiIndicator.onNetworkDisconnected(WifiIndicator)
check(live._wifiindicator_icon.icon == "wifi.open.100" and dirty == 2,
    "menu icon: a closed menu is left alone")
wificonnect.state = nil
UIManager.setDirty = function() end

-- ------------------------------------------------------ menu icon: tap --
local function clearBroadcasts()
    -- clear in place: the UIManager stub captured `broadcasts` as an upvalue,
    -- so reassigning `broadcasts = {}` would break the link
    for i = #broadcasts, 1, -1 do broadcasts[i] = nil end
end

wifi.on, wifi.connected = false, false
local menu_tap = newMenu()
clearBroadcasts()
menu_tap._wifiindicator_icon.callback()
check(broadcasts[1] == "ToggleWifi" and #broadcasts == 1,
    "menu icon: tap broadcasts ToggleWifi")
check(menu_tap._wifiindicator_icon.icon == "wifi.open.50",
    "menu icon: tap while off shows optimistic connecting state")

wifi.on, wifi.connected = true, true
local menu_tap2 = newMenu()
clearBroadcasts()
menu_tap2._wifiindicator_icon.callback()
check(broadcasts[1] == "ToggleWifi",
    "menu icon: tap while connected broadcasts ToggleWifi")
check(menu_tap2._wifiindicator_icon.icon == "wifi.open.0",
    "menu icon: tap while connected shows optimistic off state")

-- -------------------------------------------------- settings checkbox --
local menu_items = {}
WifiIndicator.addToMainMenu(WifiIndicator, menu_items)
local sub = menu_items.wifi_indicator.sub_item_table
check(menu_items.wifi_indicator.text == "Wi-Fi status & connect", "settings: menu is named 'Wi-Fi status & connect'")
check(#sub == 3, "settings: engine not installed -> no network list or background toggle, three checkboxes")
check(sub[1].text == "Hide Wi-Fi popups" and sub[2].text == "Show Wi-Fi status in corner"
    and sub[3].text == "Show Wi-Fi status in menu bar", "settings: checkbox labels and order")
check(sub[3].checked_func() == true, "settings: menu icon default on")

wificonnect.installed = true -- as on a Kobo
local list_calls = 0
wificonnect.showNetworkList = function() list_calls = list_calls + 1 end
menu_items = {}
WifiIndicator.addToMainMenu(WifiIndicator, menu_items)
sub = menu_items.wifi_indicator.sub_item_table
check(#sub == 5 and sub[1].text == "Show network list" and sub[1].separator
    and sub[2].text == "Connect in the background",
    "settings: engine installed -> 'Show network list' on top, then 'Connect in the background'")
sub[1].callback()
check(list_calls == 1 and sub[1].checked_func == nil, "settings: 'Show network list' is an action, not a checkbox")
wificonnect.showNetworkList = nil -- installed flag set, but the action isn't there
menu_items = {}
WifiIndicator.addToMainMenu(WifiIndicator, menu_items)
check(#menu_items.wifi_indicator.sub_item_table == 3,
    "settings: no engine actions unless the engine really set them up (no crash on tap)")
wificonnect.installed = false

-- ---------------------------------------------- delete plugin settings --
local deleted = {}
_G.G_reader_settings.delSetting = function(self, key) table.insert(deleted, key) end
WifiIndicator.deletePluginSettings(WifiIndicator)
table.sort(deleted)
check(#deleted == 4
    and deleted[1] == "wifiindicator_menu_icon"
    and deleted[2] == "wifiindicator_nonblocking_wifi"
    and deleted[3] == "wifiindicator_show_icon"
    and deleted[4] == "wifiindicator_suppress_popups",
    "settings: deletePluginSettings removes all four keys")

-- ---------------------------------------------------- status presenter --
local scheduled = {}
UIManager.scheduleIn = function(self, seconds) table.insert(scheduled, seconds) end
local function lastIcon()
    local frame = shown[#shown]
    return frame and frame[1] and frame[1].icon
end
settings_data.wifiindicator_show_icon = true

shown, scheduled = {}, {}
wificonnect.on_status("connecting")
check(lastIcon() == "wifi.open.50" and scheduled[#scheduled] == 90,
    "presenter: connecting shows the connecting icon, capped at 90 s")
wificonnect.on_status("connecting")
check(#shown == 1 and #scheduled == 2,
    "presenter: same state again restarts the timer without redrawing")
wificonnect.on_status("connected", { ssid = "Home" })
check(lastIcon() == "wifi.open.100" and scheduled[#scheduled] == 3,
    "presenter: connected shows the connected icon for 3 s")
WifiIndicator.onNetworkDisconnected(WifiIndicator)
check(lastIcon() == "wifi.open.0", "presenter: NetworkDisconnected shows the off icon")
wificonnect.on_status("problem")
check(lastIcon() == "notice-warning" and scheduled[#scheduled] == 5,
    "presenter: problem shows the warning triangle for 5 s")
local closed = 0
UIManager.close = function() closed = closed + 1 end
local shown_before = #shown
wificonnect.on_status("choose")
check(closed == 1 and #shown == shown_before,
    "presenter: 'choose' (network list up) hides the icon instead of drawing one")

shown = {}
UIManager:show({ text = "Error connecting to the network" })
check(#shown == 1 and lastIcon() == "notice-warning",
    "presenter: KOReader's connection error popup becomes the warning triangle")

shown = {}
UIManager:show({ text = "Turning on Wi-Fi…" })
check(#shown == 1 and lastIcon() == "wifi.open.50",
    "presenter: intercepted popup is replaced by its status icon")

settings_data.wifiindicator_show_icon = false
shown = {}
wificonnect.on_status("connected")
check(#shown == 0, "presenter: icon setting off -> nothing shown")

print(failures == 0 and "ALL TESTS PASSED" or (failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
