--[[--
Wi-Fi status icon plugin.

Suppresses the Wi-Fi connection InfoMessage popups (the ones that show up
when Wi-Fi is being restored after waking up the device, among others) and
shows a small, transient Wi-Fi status icon in the top left corner of the
screen instead.

@module koplugin.WifiIndicator
--]]--

local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local IconWidget = require("ui/widget/iconwidget")
local NetworkMgr = require("ui/network/manager")
local Size = require("ui/size")
local TouchMenu = require("ui/widget/touchmenu")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

-- Non-blocking Wi-Fi connect engine (no-op on non-wpa_supplicant platforms, or when
-- the standalone koreader-nonblocking-wifi user patch is already installed).
local wificonnect = require("wificonnect")
wificonnect.install()

-- Icon size, in unscaled pixels.
local ICON_SIZE = 24
-- Distance from the screen corner, in unscaled pixels.
local ICON_MARGIN = 4

-- How each Wi-Fi state looks: its KOReader icon (menu bar and corner), and how many
-- seconds the corner icon stays up (no `corner`: menu bar only). This is the one place
-- to change the look. "connecting" stays up until the attempt reports back; its value
-- is only a safety net (the engine's worst case is about 75 s).
local LOOKS = {
    off = { icon = "wifi.open.0", corner = 3 }, -- all waves faint
    on = { icon = "wifi.open.25" }, -- Wi-Fi on, not connected: dot only
    connecting = { icon = "wifi.open.50", corner = 90 },
    connected = { icon = "wifi.open.100", corner = 3 },
    problem = { icon = "notice-warning", corner = 5 }, -- warning triangle
}

-- Turn a (translated) message template into an anchored Lua pattern:
-- escape pattern magic characters, and let the %1 placeholder match anything
-- (it's substituted with the SSID at display time).
local function msgToPattern(msg)
    local pat = msg:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    pat = pat:gsub("%%%%1", ".-")
    return "^" .. pat .. "$"
end

-- The popups we intercept, mapped to the status (if any) shown in their stead.
-- These must be the exact source strings used by NetworkMgr/NetworkListener/
-- NetworkSetting, so that gettext resolves them to the same translations.
local INTERCEPTED_MESSAGES = {
    { msg = _("Connecting to network %1…"), state = "connecting" }, -- NetworkMgr (Kindle)
    { msg = _("Connected to network %1"), state = "connected" }, -- NetworkMgr, NetworkSetting
    { msg = _("Scanning for networks…"), state = "connecting" }, -- NetworkMgr:reconnectOrShowNetworkMenu
    { msg = _("Connection failed"), state = "problem" }, -- NetworkMgr:reconnectOrShowNetworkMenu
    { msg = _("Error connecting to the network"), state = "problem" }, -- NetworkMgr
    { msg = _("Unable to communicate with the Wi-Fi backend"), state = "problem" }, -- Kindle getNetworkList
    { msg = _("Scanning for Wi-Fi networks timed out"), state = "problem" }, -- Kindle getNetworkList
    { msg = _("Connecting to Wi-Fi…"), state = "connecting" },
    { msg = _("Waiting for network connectivity…"), state = "connecting" },
    { msg = _("Turning on Wi-Fi…"), state = "connecting" },
    { msg = _("Turning off Wi-Fi…") },
    { msg = _("Disconnecting…") }, -- NetworkSetting, before joining another network
    { msg = _("Wi-Fi off."), state = "off" },
    { msg = _("Already connected to network %1."), state = "connected" },
    { msg = _("Already connected."), state = "connected" },
    { msg = _("You can now retry the action that required network access") },
}
for __, entry in ipairs(INTERCEPTED_MESSAGES) do
    entry.pattern = msgToPattern(entry.msg)
end

-- Module-level, so the icon and the UIManager.show patch are shared between
-- the FileManager and ReaderUI instances of the plugin.
local icon_frame, icon_frame_name
local hideIcon, showIcon

hideIcon = function()
    UIManager:unschedule(hideIcon)
    if icon_frame then
        UIManager:close(icon_frame, "ui")
        icon_frame, icon_frame_name = nil, nil
    end
end

showIcon = function(icon_name, timeout)
    if icon_frame and icon_frame_name == icon_name then
        -- Already showing it: just restart the timer, no extra e-ink refresh.
        UIManager:unschedule(hideIcon)
        UIManager:scheduleIn(timeout, hideIcon)
        return
    end
    hideIcon()
    icon_frame_name = icon_name
    icon_frame = FrameContainer:new{
        bordersize = 0,
        padding = Size.padding.small,
        toast = true, -- transparent to input, stacked on top
        IconWidget:new{
            icon = icon_name,
            width = Screen:scaleBySize(ICON_SIZE),
            height = Screen:scaleBySize(ICON_SIZE),
            alpha = true, -- keep the icon's transparency instead of flattening onto white
        },
    }
    local margin = Screen:scaleBySize(ICON_MARGIN)
    UIManager:show(icon_frame, "ui", nil, margin, margin)
    UIManager:scheduleIn(timeout, hideIcon)
end

local refreshMenuIcon -- defined with the menu bar icon below

-- Status changes. The engine (wificonnect.lua), KOReader's Network events and the
-- intercepted popups only report a state; LOOKS decides what that looks like. States
-- with no corner look (e.g. "choose", when the network list is up) hide the corner icon.
-- An open menu's icon is refreshed too.
local function presentStatus(state)
    refreshMenuIcon()
    local look = LOOKS[state]
    if not (look and look.corner) or not G_reader_settings:nilOrTrue("wifiindicator_show_icon") then
        return hideIcon()
    end
    showIcon(look.icon, look.corner)
end
-- First load wins, like the patches below: they share its module-level state.
if not wificonnect._wifiindicator_wired then
    wificonnect._wifiindicator_wired = true
    wificonnect.on_status = presentStatus
end

local function interceptedIcon(widget)
    if not widget or type(widget.text) ~= "string" then
        return
    end
    for __, entry in ipairs(INTERCEPTED_MESSAGES) do
        if widget.text:match(entry.pattern) then
            return entry
        end
    end
end

-- Wrap UIManager:show once, to filter out the Wi-Fi popups.
if not UIManager._wifiindicator_orig_show then
    UIManager._wifiindicator_orig_show = UIManager.show
    UIManager.show = function(self, widget, ...)
        if G_reader_settings:nilOrTrue("wifiindicator_suppress_popups") then
            local entry = interceptedIcon(widget)
            if entry then
                logger.dbg("WifiIndicator: suppressed popup:", widget.text)
                if entry.state then
                    presentStatus(entry.state)
                end
                return
            end
        end
        return UIManager._wifiindicator_orig_show(self, widget, ...)
    end
end

-- The menu bar's state: KOReader's live Wi-Fi state, plus what the engine is doing
-- (only it knows about "connecting" and "problem").
local function menuState()
    if NetworkMgr:isConnected() then
        return "connected"
    elseif wificonnect.state == "connecting" then
        return "connecting" -- checked before isWifiOn: the radio is still off during bring-up
    elseif not NetworkMgr:isWifiOn() then
        return "off"
    elseif wificonnect.state == "problem" then
        return "problem"
    end
    return "on"
end

local function wifiStateIcon()
    return LOOKS[menuState()].icon
end

-- The last menu that got our icon. Weak, so a closed menu can be collected.
local last_menu = setmetatable({}, { __mode = "v" })

-- Keep the menu bar icon current while the menu stays open (otherwise it would only
-- update on the next updateItems or menu open).
refreshMenuIcon = function()
    local menu = last_menu[1]
    local button = menu and menu._wifiindicator_icon
    if not button or not UIManager:isWidgetShown(menu.show_parent) then
        return
    end
    local icon = wifiStateIcon()
    if button.icon ~= icon then
        button:setIcon(icon)
        UIManager:setDirty(menu.show_parent, "ui", button.dimen)
    end
end

-- Wi-Fi status icon in the TouchMenu footer, left of the clock.
-- The menu is rebuilt on every open, so the setting takes effect on the
-- next open, and state is never stale.
if not TouchMenu._wifiindicator_orig_init then
    TouchMenu._wifiindicator_orig_init = TouchMenu.init
    TouchMenu.init = function(menu)
        TouchMenu._wifiindicator_orig_init(menu)
        if not G_reader_settings:nilOrTrue("wifiindicator_menu_icon") then
            return
        end
        if not menu.device_info then
            logger.warn("WifiIndicator: TouchMenu.device_info not found, skipping menu icon")
            return
        end
        local icon_size = Screen:scaleBySize(menu.fface and menu.fface.orig_size or 20)
        menu._wifiindicator_icon = IconButton:new{
            icon = wifiStateIcon(),
            width = icon_size,
            height = icon_size,
            show_parent = menu.show_parent,
            callback = function()
                -- Optimistic state; the true state is re-read on the next
                -- updateItems call or menu open.
                local turning_on = not NetworkMgr:isWifiOn()
                menu._wifiindicator_icon:setIcon(LOOKS[turning_on and "connecting" or "off"].icon)
                UIManager:setDirty(menu.show_parent, "ui")
                UIManager:broadcastEvent(Event:new("ToggleWifi"))
            end,
        }
        table.insert(menu.device_info, 1, HorizontalSpan:new{ width = Size.span.horizontal_default })
        table.insert(menu.device_info, 1, menu._wifiindicator_icon)
        menu.device_info:resetLayout()
        last_menu[1] = menu
    end
end

if not TouchMenu._wifiindicator_orig_updateItems then
    TouchMenu._wifiindicator_orig_updateItems = TouchMenu.updateItems
    TouchMenu.updateItems = function(menu, ...)
        TouchMenu._wifiindicator_orig_updateItems(menu, ...)
        if menu._wifiindicator_icon then
            -- setIcon is a no-op when the icon name is unchanged
            menu._wifiindicator_icon:setIcon(wifiStateIcon())
        end
    end
end

local WifiIndicator = WidgetContainer:extend{
    name = "wifiindicator",
    is_doc_only = false,
}

function WifiIndicator:init()
    self.ui.menu:registerToMainMenu(self)
end

-- A checkbox bound to a default-on setting.
local function settingItem(text, key, help_text)
    return {
        text = text,
        help_text = help_text,
        checked_func = function() return G_reader_settings:nilOrTrue(key) end,
        callback = function() G_reader_settings:flipNilOrTrue(key) end,
    }
end

function WifiIndicator:addToMainMenu(menu_items)
    local sub_item_table = {}
    if wificonnect.installed then
        table.insert(sub_item_table, {
            text = _("Show network list"),
            help_text = _("Scan for networks now and show the list, e.g. to switch networks. Turns Wi-Fi on first if it's off."),
            callback = function() wificonnect.showNetworkList() end,
            separator = true,
        })
        table.insert(sub_item_table, settingItem(_("Connect in the background"), "wifiindicator_nonblocking_wifi",
            _("Keep reading while Wi-Fi connects, and reconnect after sleep to networks saved in KOReader. When off, KOReader connects the standard way and the screen freezes while it does. Takes effect on the next connection.")))
    end
    table.insert(sub_item_table, settingItem(_("Hide Wi-Fi popups"), "wifiindicator_suppress_popups"))
    table.insert(sub_item_table, settingItem(_("Show Wi-Fi status in corner"), "wifiindicator_show_icon"))
    table.insert(sub_item_table, settingItem(_("Show Wi-Fi status in menu bar"), "wifiindicator_menu_icon"))
    menu_items.wifi_indicator = {
        text = _("Wi-Fi status & connect"),
        sorting_hint = "network",
        sub_item_table = sub_item_table,
    }
end

-- Called by the plugin manager's "Disable/Delete plugin and settings" buttons
-- (KOReader nightly, koreader/koreader#15240). No-op on older versions.
function WifiIndicator:deletePluginSettings()
    for __, key in ipairs({
        "wifiindicator_suppress_popups",
        "wifiindicator_show_icon",
        "wifiindicator_menu_icon",
        "wifiindicator_nonblocking_wifi",
    }) do
        G_reader_settings:delSetting(key)
    end
end

-- These events are broadcast by NetworkMgr, and are what actually tells us
-- the connection state changed (the Kindle Wi-Fi restore on wakeup is
-- asynchronous, and doesn't necessarily go through any of the popups above).
function WifiIndicator:onNetworkConnected()
    presentStatus("connected")
    -- Don't return true: NetworkListener & co. need this event, too.
end

function WifiIndicator:onNetworkDisconnected()
    presentStatus("off")
end

-- Don't leave a stale icon around across suspend/exit.
function WifiIndicator:onSuspend()
    hideIcon()
end

function WifiIndicator:onCloseWidget()
    hideIcon()
end

return WifiIndicator
