# Plan: hand KOReader's saved networks to wpa_supplicant

_Status: **done**. Scenarios A, C and I passed on the Clara BW, and it was merged into `main` on 2026-09-28. Checked against KOReader **v2026.07.1**. Kept as a record. Later change: the `failed` state below was replaced on branch `icon-states` by `problem` / `choose` / `off` (see the `LOOKS` table in `main.lua` and `CLAUDE.md`)._

This replaces `nbwifi.lua` with a smaller Kobo-only connect engine, built on its own branch and merged only if on-device testing shows it works better than `main`. Background and the KOReader source findings behind it are in `CLAUDE.md` under *Project context*.

## The idea in one paragraph

Today (stock KOReader, and `nbwifi.lua`, which copies stock's logic), KOReader drives the connection itself: scan, match the results against its own saved list, push saved networks to wpa_supplicant one at a time (up to 30 s each), then DHCP. wpa_supplicant only knows the Kobo OS's networks on its own, so networks saved only in KOReader never come back on wake. The new engine instead **hands every KOReader-saved network to wpa_supplicant right after it starts and lets wpa_supplicant pick and join one**, the same way it already handles the Kobo OS's networks. All slow steps stay off the UI thread. **The engine shows no popups of its own; it reports its state, and `main.lua` turns that into the status icon.**

## Success criteria (measured on the Clara BW)

1. The UI never freezes during a connect (page turns and menus respond throughout), including when **joining from the network list**.
2. A network saved only in KOReader connects from the menu toggle, from actions that need the network (sync, OPDS), and **on wake from sleep** with "Automatically restore Wi-Fi connection after resume" on.
3. In the normal case (a known network in range), time until connected is no worse than `main`.
4. With no known network in range, it gives up in about 15 s without freezing. If you turned Wi-Fi on yourself, it then shows the network list.
5. Turning Wi-Fi off in the middle of a connect cancels cleanly, with no leftover background work and no stray popups.
6. While connecting, a "connecting" icon stays visible until the connect succeeds or fails. No Wi-Fi popup covers the page at any point.

## Verified facts this relies on (KOReader v2026.07.1, identical to master on 2026-09-28)

- `enable-wifi.sh` starts wpa_supplicant with the Kobo OS's config (`/mnt/onboard/.kobo/wpa_supplicant.conf` on FW 5.x) **only if it isn't already running** (`pkill -0 wpa_supplicant ||`).
- `disable-wifi.sh` runs `wpa_cli terminate`, so networks we add are gone after Wi-Fi turns off. We re-add them on every connect, which also means we never write to the Kobo OS's config file.
- KOReader's saved networks: `NetworkMgr:getAllSavedNetworks()` returns a LuaSettings object (`settings/network.lua`) keyed by SSID, with `ssid`, `password`, `psk`, `flags`. `psk` can be missing until first use. Stock computes it with PBKDF2 (4096 rounds, CPU-heavy) and saves it.
- The lj-wpaclient calls we need exist: `listNetworks`, `addNetwork`, `setNetwork`, `enableNetworkByID`, `getConnectedNetwork`, `removeNetwork`, `close`. The SSID must be hex-encoded for `SET_NETWORK ssid`. `listNetworks()` returns SSIDs in wpa_supplicant's escaped form (`\xNN`), so decode before comparing.
- Callers:
  - `NetworkMgr:enableWifi` → `requestToTurnOnWifi` → `turnOnWifi(complete_callback, interactive)`. `complete_callback` schedules KOReader's connectivity check, which broadcasts `NetworkConnected`. A `nil` return means "pending", and on failure we must call `_abortWifiConnection()` ourselves.
  - On wake and at startup, `NetworkListener:onResume` / `NetworkMgr:init` call `restoreWifiAsync()` and then `scheduleConnectivityCheck()` themselves. That check gives up after 45 s and records `lease_ssid` on success.
- **Network list** (`frontend/ui/widget/networksetting.lua`): `NetworkItem:connect()` calls `NetworkMgr:authenticateNetwork()` synchronously (up to 30 s, showing "Authenticating…" and raw wpa state/event popups), then a local `obtainIP()` ("Obtaining IP address…", then `dhcpcd -w` for up to 30 s), then shows "Connected." or the error. `NetworkItem` is a module-local class. It can be reached as an upvalue of `NetworkSetting.init` via `debug.getupvalue`; if that lookup fails, leave stock behavior in place.

## Design

New file `wificonnect.lua` replaces `nbwifi.lua`. It only installs when `NetworkMgr.wpa_supplicant` is set, which covers Kobo. The Kindle backend is dropped, which is in line with the fork's goals.

**Kept from `nbwifi.lua`** (proven parts):
- `subprocessCall` with `drainPipe` and the `FD_CLOEXEC` guard, so we never block on the pipe (see the hard-lock warning in `nbwifi.lua`).
- `pollUntil` and the `gen` counter that cancels in-flight work on `disableWifi` / `_abortWifiConnection`.
- Forking the stock `turnOnWifi` with the reconnect step stubbed out, for hardware bring-up.
- The `wifiindicator_nonblocking_wifi` setting as the kill switch: off means pure stock behavior.

**Dropped:**
- Scan-first flow, one-network-at-a-time `tryPreferred`, the Kindle backend, and the engine's own popups.
- The `_nbwifi_installed` coordination with the standalone user patch; the user doesn't run it. Leave a one-line guard that skips installing if that flag is already set, so the two can never double-patch.

### Status reporting (engine → icon)

The engine never calls `UIManager:show` for status. It calls `M.on_status(state, info)`, which `main.lua` sets. The states are:

| State | When | Default presentation (`main.lua`) |
|---|---|---|
| `connecting` | Pipeline starts | "Connecting" icon in the corner, **stays up** (no timeout) |
| `connected` | Finished, with SSID in `info` | "Connected" icon for 3 s |
| `failed` | Gave up or was cancelled with an error | "Disconnected" icon for 3 s |
| `idle` | Cancelled by the user (Wi-Fi turned off) | Hide the icon |

The `onNetworkConnected` / `onNetworkDisconnected` handlers in `main.lua` feed the same presenter, so status from KOReader's own events and from the engine looks identical. **Keep all presentation choices (icons, position, timeouts) in one place in `main.lua`.** The user wants to talk about other icon options and customizing the notification later (see `CLAUDE.md`), and that should only mean changing the presenter.

The interactive fallbacks still show KOReader's own UI, because the user asked for them: the network list when nothing connects, and the password prompt.

### Pipeline

The same pipeline runs for every entry point:

```
bringUp()        subprocess: stock turnOnWifi with reconnect stubbed    (skip if Wi-Fi is already on)
handOff()        UI thread, a few fast socket calls:
                   known = listNetworks()                                (Kobo OS networks + anything already added)
                   for each KOReader-saved network whose SSID is not in known:
                     addNetwork → setNetwork ssid (hex) → psk | key_mgmt NONE → enableNetworkByID
waitForJoin()    pollUntil getConnectedNetwork() every 250 ms, JOIN_TIMEOUT_S = 15
getIP()          subprocess: NetworkMgr:obtainIP()                     (DHCP_TIMEOUT_S = 30)
finish()         lease_ssid = ssid; complete_callback(); on_status("connected", {ssid = ssid})
```

On join timeout: if the user turned Wi-Fi on themselves, run one scan in a subprocess and show the stock `NetworkSetting` list. Otherwise call `_abortWifiConnection()` and report `failed`.

### Entry points

| Entry point | New behavior |
|---|---|
| `NetworkMgr:turnOnWifi` | Full pipeline. Returns `nil` (pending). |
| `NetworkMgr:reconnectOrShowNetworkMenu` | Pipeline without `bringUp()`, since Wi-Fi is already on. Covers any caller that reaches it directly. |
| `NetworkMgr:restoreWifiAsync` | Pipeline with no callback. The caller's own connectivity check broadcasts `NetworkConnected` and sets `lease_ssid`. |
| Long-press Wi-Fi toggle (`wifi_toggle_long_press`) | After success, scan in a subprocess and show the list, like stock. |
| **Network list: tap a network** (`NetworkItem:connect`) | Disconnect the current item (as stock does), then run `handOff` for that one network → `waitForJoin` → `getIP` in the background. Afterwards, update the item (`info.connected`, `setConnectedItem`, `refresh`) and call `setting_ui.connect_callback` on success, as stock does. Report status through `on_status`. On failure, show the stock error text, since the user is looking at the list and expects an answer there. |

### PSK cost

If a saved network has no `psk`, compute it once and save it through `NetworkMgr:saveNetwork`, as stock does. Measure the cost on the Clara BW. If it's noticeable, compute it inside the `bringUp()` subprocess and return it to the parent.

## Phases

0. **Prep (done 2026-09-28).** KOReader v2026.07.1 confirmed and the facts above re-checked against it. `main` works on the device. LuaJIT installed; all tests pass. The current work is committed on `main`, and the branch is created from it.
1. **Pure logic plus unit tests.** Put the "which networks to add and how" logic in plain functions: decode SSIDs from `listNetworks()`, dedupe, open network vs PSK, SSID hex encoding, and building the list of `SET_NETWORK` commands. Unit-test them with no KOReader dependencies in `test/test_wificonnect.lua`.
2. **Engine.** Implement `bringUp` / `handOff` / `waitForJoin` / `getIP` / `finish` with cancellation and `on_status`, and hook the `turnOnWifi` and `reconnectOrShowNetworkMenu` entry points.
3. **Wake restore.** Hook `restoreWifiAsync`.
4. **Network list.** Hook `NetworkItem:connect` as described above.
5. **Presenter and wiring.**
   - `main.lua` gets a single status presenter (persistent "connecting", 3 s result) fed by both `on_status` and the Network events.
   - Require `wificonnect` instead of `nbwifi`, keeping the menu toggle text.
   - Delete `nbwifi.lua`.
   - Update the README and `CLAUDE.md` architecture sections, and the tests.
6. **On-device testing** (below), compared against `main`.
7. **Decide.** Merge to `main` if it meets the success criteria and beats `main`. Otherwise keep `main` and record why in `CLAUDE.md`.

Follow-ups after the merge (from the roadmap in `CLAUDE.md`): an on-device popup audit, a KOReader-update diff script, and README/housekeeping.

## On-device test scenarios

Run each on `main` (baseline) and on the branch. For each run, note: freeze (yes/no), seconds until connected, popups seen, and outcome.

| # | Scenario |
|---|---|
| A | Menu toggle on, at a network known **only to KOReader** |
| B | Menu toggle on, at a network known to the Kobo OS |
| C | Wake from sleep with auto-restore on, KOReader-only network |
| D | Wake from sleep with auto-restore on, Kobo OS network |
| E | Menu toggle on with **no** known network in range (should give up in about 15 s, then show the list) |
| F | An action that needs the network (e.g. sync) with Wi-Fi off and "turn on" as the action |
| G | Turn Wi-Fi off in the middle of a connect |
| H | Two saved networks in range, one with a wrong password |
| I | Network list: tap a saved network |
| J | Network list: tap a new network and enter its password (right and wrong) |

Logs: enable verbose debug logs in KOReader, and grep `crash.log` for `wificonnect:`.

## Open questions to settle during the work

1. Does `ENABLE_NETWORK` on a disconnected wpa_supplicant trigger an immediate scan and join, or do we need to send `REASSOCIATE`? Check on device; add it if joins are slow.
2. How long does PBKDF2 take per network on the Clara BW? (It decides the "PSK cost" option above.)
3. Hidden networks (no SSID broadcast) are out of scope unless the user needs them. They would require `scan_ssid=1`.
4. Network list: when joining fails with a wrong password, stock shows wpa_supplicant's error text. Keep that, or map it to a friendlier message?
