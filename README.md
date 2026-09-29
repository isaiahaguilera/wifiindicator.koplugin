# Wi-Fi status & connect — a KOReader plugin for Kobo

Stock KOReader on Kobo freezes the screen while Wi-Fi connects (5 seconds or
more, longer when no known network is around), covers your page with popups
at every step, and only reconnects on its own to networks the Kobo OS already
knows. This plugin fixes all three: Wi-Fi connects in the background, the
popups are replaced by a small status icon, and networks you saved in
KOReader reconnect just like the Kobo's own.

Tested on a **Kobo Clara BW** with **KOReader v2026.07.1**.

## What it does

- **Connects in the background.** Turning Wi-Fi on, actions that need the
  network (sync, OPDS…), reconnecting after sleep, and joining from the
  network list all happen without freezing the screen.
- **Reconnects to your KOReader networks.** Networks saved in KOReader come
  back after sleep, even if you never joined them in the Kobo OS.
- **Hides Wi-Fi popups.** "Turning on Wi-Fi…", "Connecting…", "Wi-Fi off."
  and the rest are replaced by the status icon.
- **Shows Wi-Fi status** as a small icon in the top-left corner and in the
  menu's bottom bar. Tap the menu-bar icon to turn Wi-Fi on or off.
- **Cleans up the network list.** A network broadcast by several radios (a
  dual-band 2.4/5 GHz router, or a mesh) is listed once. Connecting is by
  name; the Kobo picks the radio.

### What the icons mean

KOReader's built-in icons, one per state, in both places:

| Icon | Meaning | Corner icon |
|---|---|---|
| all waves faint | Wi-Fi off | 3 s |
| dot only | Wi-Fi on, not connected | — (menu bar only) |
| half the waves | connecting | until it finishes |
| full | connected | 3 s |
| warning triangle | something went wrong | 5 s |

If you turn Wi-Fi on and no saved network is in range, the network list opens
instead: nothing went wrong, it's your pick. If the device wakes up somewhere
with no saved network, it turns Wi-Fi back off quietly.

## Menu

**Menu → Network → Wi-Fi status & connect** (long-press the first two items
for details):

- **Show network list**: scans now and shows the list, e.g. to switch
  networks. Turns Wi-Fi on first if it's off.
- **Connect in the background**: off means KOReader's standard connect,
  which freezes the screen.
- **Hide Wi-Fi popups**: independent of the icons.
- **Show Wi-Fi status in corner** / **Show Wi-Fi status in menu bar**

To edit or forget a saved network, use the **edit** button on its row in the
network list. The network you're connected to shows **disconnect** instead;
disconnect first to edit it.

## Install

1. Download **`wifistatus.koplugin.zip`** from the
   [latest release](../../releases/latest) and unzip it. It contains a
   `wifistatus.koplugin/` folder with the three files the plugin needs.
2. Connect the Kobo over USB and copy that folder into the hidden
   `.adds/koreader/plugins/` folder.
3. **Upgrading from an older version** (named `wifiindicator.koplugin`, or the
   original asxelot plugin): delete the old `wifiindicator.koplugin` folder, so
   there aren't two copies. Your settings carry over.
4. Eject, then restart KOReader.

On devices that don't use wpa_supplicant (anything but Kobo and similar), the
background connect stays off; the popup hiding and the icons still work.

### Updating with Storefront

The [Storefront](https://github.com/ultimatejimmy/storefront.koplugin) plugin
can check this repo's releases and update the plugin in one tap. Link the
installed plugin to **this repository** in Storefront once. Don't accept an
update that points at `asxelot/wifiindicator.koplugin`: that's the original
plugin (v1.0.0), and installing it would replace this one.

## How it works

KOReader has no hooks for any of this, so the plugin patches KOReader at load
time (each patch applied once):

- **`wificonnect.lua`**, the connect engine, replaces KOReader's Wi-Fi
  turn-on, reconnect and after-sleep restore, plus the network list's connect.
  Once the Wi-Fi chip is up, it hands every network saved in KOReader to
  wpa_supplicant (in memory only; the Kobo OS's own config file is never
  touched) and lets wpa_supplicant pick one. The slow steps (chip start-up,
  DHCP, scans) run in background processes; the screen never waits on them.
- **`main.lua`** filters KOReader's Wi-Fi popups, adds the menu-bar icon and
  the menu, and turns the engine's state into icons. All icon choices live in
  its `LOOKS` table.

**Caveat:** popups are matched by KOReader's exact wording. If a KOReader
release rewords one, that popup shows again until `INTERCEPTED_MESSAGES` in
`main.lua` is updated.

## Development

Three self-contained test suites, run from the repo root with LuaJIT:

```sh
luajit test/test_main.lua main.lua   # plugin: popup filter, icons, menu, settings
luajit test/test_wificonnect.lua     # engine: pure network logic
luajit test/test_engine.lua          # engine: simulated connect flows (fake KOReader + wpa_supplicant)
```

The engine simulation checks flow and bookkeeping; real timing and hardware
behavior need a device. `CLAUDE.md` holds the project's working notes and
history, and `docs/plan-wpa-handoff.md` explains the engine's design.

### Releasing

1. Bump `version` in `_meta.lua` (e.g. `2.0.1`) and commit.
2. Tag and push: `git tag v2.0.1 && git push origin main v2.0.1`.

The **Release** workflow (`.github/workflows/release.yml`) runs the tests,
checks the tag matches `_meta.lua`, and publishes the release with
`wifistatus.koplugin.zip` attached. Storefront picks it up from there.

## Credits & license

A personal fork of [asxelot/wifiindicator.koplugin](https://github.com/asxelot/wifiindicator.koplugin)
by Eugene Ryzhkov. The connect engine grew out of their
[koreader-nonblocking-wifi](https://github.com/asxelot/koreader-nonblocking-wifi)
user patch and keeps its background-process machinery. If that patch is
installed too, it takes precedence and this plugin's engine stays off. You
only need one.

GPL-3.0 — see [LICENSE](LICENSE).
