# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

It is a **working document**: it holds the project's shared context, not just the reference below. A fresh session with no memory should be able to read this file and pick up where the last one stopped.

## Rules for Claude (read first)

1. **Start of session:** read *Current state* and *Open threads* below before doing anything else. Treat them as the handoff from the previous session. Verify anything that names a file, function or flag before relying on it, since the code may have moved on.
2. **Mirror memories here.** Whenever you save, update or delete a memory in this project's Claude Code memory directory (`~/.claude/projects/<this-project>/memory/`), make the same change in *Project context* below **in the same turn**. The memory directory is local to one machine; this file travels with the repo, so it is the source of truth.
   - Mirror `project`, `feedback` and `reference` memories. Keep `user`-type memories (personal details about the user) out of this file, because the repo is public.
   - One bullet per memory, tagged with its type and date. For `feedback`/`project` entries, keep the **Why** so a later session can judge edge cases.
   - If a memory turns out to be wrong, remove it from both places.
3. **Keep the handoff current.** Before ending a piece of work (or when the user wraps up), update *Current state*, *Open threads* and add a dated entry to the *Session log*. Write it for a reader with zero context: say what was done, what's half-done, and what the next concrete step is.
4. Use absolute dates (YYYY-MM-DD), never "yesterday" or "last week".
5. Edits to this file are normal changes: include them in commits alongside the code they describe. Don't commit or push unless the user asks.

## Current state

_Last updated: 2026-09-28_

- This repo is **Isaiah Aguilera's fork** (`origin` = `github.com/isaiahaguilera/wifiindicator.koplugin`) of Eugene Ryzhkov's (`asxelot`) plugin. No `upstream` remote is configured.
- Target device: **Kobo Clara BW**, KOReader **v2026.07.1** (wpa_supplicant backend). Goals are under *Project context*.
- **`main`:** same features as upstream, minus the emulator-only test code in `nbwifi.lua`, plus `CLAUDE.md` and `docs/plan-wpa-handoff.md`. It **works on the device** (user confirmed 2026-09-28). `luajit test/test_main.lua main.lua` passes.
- **Active work: branch `wpa-handoff`.** Follow **`docs/plan-wpa-handoff.md`** (read it first). It replaces `nbwifi.lua` with `wificonnect.lua`, which hands KOReader's saved networks to wpa_supplicant and lets it pick. It also makes joining from the network list non-blocking and adds a status presenter in `main.lua` with a "connecting" icon that stays up. Merge into `main` only after the on-device comparison in the plan.
- **Branch status (2026-09-28): code complete for plan phases 1–5, waiting on phase 6 (on-device testing by the user).** `nbwifi.lua` is deleted on the branch; `wificonnect.lua`, the presenter in `main.lua`, README and tests are updated. All three test suites pass (36 + 21 + 26 checks), but nothing has run on the Clara BW yet. Next: the user installs the branch and runs the plan's test scenarios A–J against `main`. Watch the plan's open questions, especially whether joins need `REASSOCIATE`.
- **On-device results (Clara BW, 2026-09-28):** the user deleted their network from the Kobo OS's known list so it's saved only in KOReader. **Scenario A passed** (KOReader connects "no problem") and **scenario C passed** (it reconnects after sleep, which `main` couldn't do). **Scenario I passed** too: the network list opened, and tapping a network connected with no freeze and no popups ("all worked fine"). It isn't clear whether J (new network plus password) was tried. E, G and H weren't run; they're optional. To open the list: **long-press "Wi-Fi connection"** in the Network menu while Wi-Fi is off (a long-press while connected just turns Wi-Fi off). **Awaiting the user's decision to merge `wpa-handoff` into `main`** (recommended).
- **Size, honestly:** `wificonnect.lua` is about 400 code lines, roughly the same as `nbwifi.lua` (about 390), not the "well under half" estimated earlier. The connect logic proper shrank from about 270 to about 150 lines, but the branch adds features `nbwifi.lua` never had: joining from the network list (about 55), wake restore, and the separately tested pure logic (about 45).

## Open threads

- **Roadmap after the branch (approved 2026-09-28):** (a) on-device popup audit: add any KOReader Wi-Fi popup that still gets through to `INTERCEPTED_MESSAGES`, with tests; (b) a small script that diffs KOReader's Wi-Fi files between two releases (the files checked for v2026.07.1: `platform/kobo/{enable,disable}-wifi.sh`, `obtain-ip.sh`, `restore-wifi-async.sh`, `frontend/device/kobo/device.lua`, `frontend/ui/network/{manager,wpa_supplicant,networklistener}.lua`, `frontend/ui/widget/networksetting.lua`); (c) README/housekeeping: point install links at the fork, drop the upstream-patch coordination.
- **Icon accuracy work: proposal accepted by the user (2026-09-28), not built yet. Planned as a follow-up after merging `wpa-handoff`.** KOReader built-in icons only. Every state gets its own icon, used the same way in the corner and the menu bar:
  - `off` → `wifi.open.0` (all faint), corner 3 s when the user turns Wi-Fi off;
  - `on, not connected` → `wifi.open.25` (dot only), menu bar only;
  - `connecting` → `wifi.open.50`, corner until done;
  - `connected` → `wifi.open.100`, corner 3 s;
  - `problem` → `notice-warning` (triangle), corner about 5 s, for real failures only (bring-up failed, DHCP failed, KOReader's "Error connecting to the network").

  Changes needed: add the `problem` state; make the menu-bar icon use the same presenter states, with the engine exposing its current state so the menu bar can show connecting/problem; split "on, not connected" from "connecting". The user reported no actual blinking; the confusion was just what each icon meant. The possible "off" flash on suspend (Wi-Fi is disabled on sleep) is unverified and low priority.
- **Refinements to fold into that work (proposed 2026-09-28):**
  - (1) When an interactive connect falls back to the network list, **don't report `failed`**: hide the corner icon (the list is the message), and the menu bar shows "on, not connected" if the list is closed.
  - (2) **Skip the 15 s join wait when wpa_supplicant has nothing to try** (no networks handed off and none in `listNetworks()`). Stock skips it in that case, so the engine is currently slower than stock there.
  - (3) Optional, needs on-device verification: end the wait early once wpa_supplicant's own scan results (`SCAN_RESULTS`) show none of its configured SSIDs nearby.
- **Future discussion (user-requested, not scheduled):** other status icon options and customizing the notification. See *Project context*. Partly answered 2026-09-28: the user wants to stick to KOReader's icons.
- **"Authenticating…" TODO (deferred 2026-09-28):** on `main`, `nbwifi.lua` shows `_("Authenticating…")`, which isn't in `INTERCEPTED_MESSAGES`. The `wpa-handoff` engine makes this moot (no engine popups). Only fix it on `main` if the branch is abandoned. With the engine's kill switch off, stock's "Authenticating…" and its "Obtaining IP address…" still show; that's for the popup audit.
- **Known gap on `main`:** joining from KOReader's network list (`frontend/ui/widget/networksetting.lua` → `authenticateNetwork` + `obtainIP`) still freezes for up to about 60 s and shows popups. Fixed on the branch (`NetworkItem:connect` hook), not yet verified on the device.
- **Unverified on device (branch):** the `debug.getupvalue` lookup of `NetworkItem` (it logs "NetworkItem not found" and stays stock if it fails), `SELECT_NETWORK` behavior, and PBKDF2 cost.
- **README points at upstream** (`asxelot/…` install and patch links). Part of roadmap item (c).
- **Stale comment:** the header of `test/test_main.lua` says to run it from a KOReader checkout; it has to run from this repo root (see *Tests*).

## Project context (mirrored memories)

- `[project, 2026-09-28]` **Fork goals.** This is the user's own customized copy of asxelot's plugin. Keep its original purpose (quiet Wi-Fi status plus non-blocking connect) and make changes and updates as needed. Prioritize **performance and low memory use on a Kobo Clara BW** (the only target device for now). No plans to contribute upstream. The aim is **"clean and lean", not just "good enough"**: the shipped plugin works on the device, but the user wants simpler, smaller code. **Why:** it's a personal daily-use tool for one e-reader. The user started the fork because on their Clara BW, connecting to Wi-Fi freezes the device for at least 5 seconds, longer when no known network is found. **How to apply:** judge changes by their on-device cost on Kobo. Trimming code that's dead on Kobo is fair game (the emulator `TEST_MODE` code was removed on 2026-09-28; the Kindle backend remains). Upstream compatibility and keeping the diff mergeable don't matter.
- `[project, 2026-09-28]` **Why stock KOReader Wi-Fi misbehaves on the Clara BW** (confirmed by reading KOReader master). The user reports that stock KOReader freezes for 5+ s when connecting, won't auto-connect to networks the Kobo OS doesn't know, and struggles to reconnect to known ones unless they were first joined in the Kobo OS (they cited koreader/koreader#14790). Causes found in KOReader's source:
  - `platform/kobo/enable-wifi.sh` starts wpa_supplicant with the **Kobo OS's own config** (`/mnt/onboard/.kobo/wpa_supplicant.conf` on FW 5.x), so wpa_supplicant auto-joins Kobo-OS networks by itself.
  - KOReader-saved networks live only in KOReader's settings. `NetworkMgr:reconnectOrShowNetworkMenu` scans, then pushes them to wpa_supplicant **one at a time** (`authenticateNetwork`, up to 30 s each), then waits up to 15 s, then runs DHCP (`obtain-ip.sh` → `dhcpcd -w`, up to 30 s). All of it runs on the UI thread.
  - Wake-from-sleep auto-restore (`restore-wifi-async.sh`) only waits 15 s for a Kobo-OS network and never tries KOReader's list.
  - On MediaTek Kobos (`wlan_drv_gen4m`), `enable-wifi.sh` has about 3.5 s of fixed sleeps.
  - #14790 itself (reports "Connected" after a network switch but uses the old IP lease, so nothing loads) was fixed by KOReader PR #15618, merged 2026-07-01 and shipped in **v2026.07**. The GitHub issue still shows open.

  **Why:** these drive the redesign decision. **How to apply:** `nbwifi.lua` removes the freeze but copies stock's logic, so it inherits the split between the Kobo OS's and KOReader's network lists. Re-check line-level details against the user's KOReader version before relying on them.
- `[project, 2026-09-28]` **Redesign plan approved.** The user approved planning the "hand saved networks to wpa_supplicant" engine on a new branch, `wpa-handoff`, merged into `main` only if on-device testing shows it works better. Plan: `docs/plan-wpa-handoff.md`. **Why:** fixes the split between the Kobo OS's and KOReader's network lists while keeping the UI responsive, with less code. **How to apply:** follow the plan's phases; don't merge without the on-device comparison. As of 2026-09-28, phases 0–5 are code-complete. Phase 6 on the device: A, C and I passed; merge pending the user's OK. `wificonnect.lua` is about the same size as `nbwifi.lua`, so don't claim it's smaller.
- `[project, 2026-09-28]` **Future topic: icon options and notification customization.** The user will want to discuss different status icon options and customizing the notification (the corner toast). It isn't scheduled; raise it after the `wpa-handoff` branch or when the user brings it up. Update 2026-09-28: stick to KOReader's built-in icons; the priority is that each icon accurately means one state. A proposal was accepted (see *Open threads*). **Why:** they want the status display to fit their taste, not just upstream's defaults. **How to apply:** keep every presentation choice (icons, position, size, timeouts) in the single status presenter in `main.lua`; the engine only reports states (`connecting` / `connected` / `failed` / `idle`).
- `[feedback, 2026-09-28]` Mirror every project memory into this file and keep it working as a handoff doc (see *Rules for Claude*). **Why:** the user wants any future LLM session to recover the full context from the repo alone, with no prior memory. **How to apply:** after any memory write, update this section; before stopping, update *Current state*, *Open threads* and *Session log*.

## Session log

Newest first. One entry per working session: what changed, what was decided, what's next.

- **2026-09-28:** Ran `/init` and wrote this file (tests, architecture, settings). The user then made it a repo rule that memories are mirrored here and that this file stays a working handoff doc; it was restructured accordingly. Found that the repo is a fork with upstream-only history. The user set the fork's goals (see *Project context*) and asked how complex the plugin is. Assessed it: `main.lua` is simple (about 230 code lines); `nbwifi.lua` is the complex part (about 475 code lines, an async state machine that depends on KOReader's `NetworkMgr` internals). The review turned up the possible "Authenticating…" popup and code that never runs on Kobo. The user deferred the popup fix as a TODO and had the emulator test code removed from `nbwifi.lua` (not run through the tests, since no Lua interpreter is installed). The user confirmed a freeze of 5+ seconds on connect on their Clara BW, the reason they forked, and that it happens on stock KOReader. Read koreader/koreader#14790 and #14716 plus KOReader's Kobo Wi-Fi source; findings are under *Project context*. Proposed letting wpa_supplicant choose the network and explained it in plain terms. The user approved it for a branch. Checked a few more KOReader details (`disable-wifi.sh` terminates wpa_supplicant; how the wake-restore callers work; the lj-wpaclient API) and wrote `docs/plan-wpa-handoff.md`. Then the user reported KOReader v2026.07.1 (its Wi-Fi source matches master for our purposes), confirmed `main` works on the device, and installed LuaJIT (all 29 tests pass). They asked whether "good enough" is enough, given the aim of clean and lean. Found that joining from the network list still freezes and shows popups even with the plugin. Proposed a roadmap aimed at "best version of the mission", and the user approved it. They also flagged a future talk about icon options and notification customization. Folded the network-list fix and the status presenter into the plan, committed the `main` work, and created branch `wpa-handoff`. On the branch, built plan phases 1–5: `wificonnect.lua` (pure logic plus engine), the status presenter in `main.lua`, deletion of `nbwifi.lua`, README/`_meta.lua` updates, and a new desktop engine simulation (`test/test_engine.lua`) that caught a test-environment gap (`table.pack`) and nothing in the engine itself. Found that the new engine isn't smaller overall (see *Current state*). Next: on-device testing (plan phase 6) by the user. The user asked what was actually gained; answered with the gains table (KOReader-only networks after sleep, non-blocking network list, persistent connecting icon, no 30 s waste on a broken saved network) and admitted the everyday connect and code size are unchanged. Suggested testing just C and I. **C passed on device**, and A too. Explained how to open the network list (long-press), and **I passed**. Recommended merging. The user then asked how icons work. Explained the layout (engine, events and popups feed one presenter; the menu bar is separate), rendered KOReader's Wi-Fi icons for them, and proposed a clear state-to-icon mapping, which the user accepted. The user also asked what happens when the list is needed because no known network is nearby. That surfaced two refinements (no "failed" icon for the list fallback; skip the pointless 15 s wait), recorded under *Open threads*. Merge still awaiting the user's OK.

---

## What this is

A KOReader plugin (Lua 5.1 / LuaJIT) that suppresses Wi-Fi lifecycle popups, shows a corner status icon and a tappable menu-bar Wi-Fi icon instead, and bundles a non-blocking Wi-Fi connect engine for Kobo. Only `main.lua`, `wificonnect.lua` and `_meta.lua` ship at runtime (on `main` before the `wpa-handoff` merge, the engine is `nbwifi.lua` instead); there is no build step. Users install by copying the folder into `koreader/plugins/` (the release zip must expand to a folder named `wifiindicator.koplugin/`).

## Tests

```sh
luajit test/test_main.lua main.lua   # plugin: popup filter, menu icon, status presenter, settings
luajit test/test_wificonnect.lua     # engine: pure hand-off logic
luajit test/test_engine.lua          # engine: simulated connect flows
```

- Run from the **repo root**: `main.lua` does `require("wificonnect")`, which only resolves via `./?.lua`.
- There's no test framework and no single-test selection: each file is a script of `check(cond, label)` calls printing PASS/FAIL, exiting non-zero on any failure.
- `test_main.lua` stubs every KOReader module via `package.preload` and a global `G_reader_settings`. When `main.lua` gains a new `require`, add a matching stub. Its `ui/network/manager` stub has no `wpa_supplicant`, so the engine doesn't install there.
- `test_engine.lua` runs the real `wificonnect.lua` against a fake NetworkMgr, a fake wpa_supplicant (`WpaClient`), inline "subprocesses" that restore `NetworkMgr` afterwards (to emulate fork isolation), a fake `ffi`, and a virtual clock (`run()` drains `UIManager:scheduleIn`). It checks flow and bookkeeping, not hardware timing. It polyfills `table.pack`, because KOReader's LuaJIT has Lua 5.2 compat and a stock desktop LuaJIT doesn't.
- No `luacheck` on the dev machine. `luajit -bl <file> /dev/null` is a quick syntax check.

## Architecture

KOReader has no hooks for this, so everything works by **monkey-patching KOReader at load time**, not in `WifiIndicator:init()`.

- **Load-once guards.** KOReader instantiates the plugin twice (FileManager and ReaderUI). `main.lua`'s patches store the original under a `_wifiindicator_orig_*` field and only wrap if it's absent. `wificonnect.install()` is guarded by `NetworkMgr._nbwifi_installed`. Shared state (the corner icon frame) is module-level. The test "double plugin load still injects exactly one icon" guards this.
- **`main.lua`**
  - **Status presenter** (`presentStatus(state)` with the `PRESENTATION` table) is the single place that decides how status looks. States: `connecting` (stays up, capped at `CONNECTING_MAX_S`), `connected`, `failed`, `off` (3 s each); anything else hides the icon. Fed by the engine (`wificonnect.on_status`), the `onNetworkConnected`/`onNetworkDisconnected` handlers, and intercepted popups. Showing the same icon again only restarts its timer (no extra e-ink refresh). Keep presentation choices here; the user wants to discuss icon/notification customization later.
  - Wraps `UIManager.show` to drop `InfoMessage`s whose `text` matches `INTERCEPTED_MESSAGES` (each entry maps to a presenter `state`). Entries must be the *exact* source strings from KOReader, wrapped in `_()` so gettext resolves them to the same translation; `msgToPattern` turns `%1` into a wildcard. If KOReader changes its wording, update this list.
  - Wraps `TouchMenu.init` / `TouchMenu.updateItems` for the menu-bar icon. Tapping broadcasts `ToggleWifi`.
  - Network event handlers must **not** return `true` (other listeners need the events).
- **`wificonnect.lua`** (see `docs/plan-wpa-handoff.md` for the why). The top part is pure, tested logic (`decodeSSID`, `toHex`, `needsPsk`, `networkParams`, `pickNetworks`). `M.install()` hooks `NetworkMgr` only when `NetworkMgr.wpa_supplicant` is set:
  - Entry points: `turnOnWifi` (bring-up, then connect), `reconnectOrShowNetworkMenu` (connect), `restoreWifiAsync` (wake/startup), and the network list's `NetworkItem:connect`. `NetworkItem` is module-local in KOReader, found via `debug.getupvalue(NetworkSetting.init, …)` and patched lazily the first time the engine shows the list. Each entry point falls back to stock when the `wifiindicator_nonblocking_wifi` setting is off.
  - Flow: `bringUp` (stock `turnOnWifi` in a subprocess with reconnect stubbed) → `handOff` (add KOReader networks wpa_supplicant doesn't know; psk derived once and saved) → `joinAndGetIP` (poll `getConnectedNetwork` up to 15 s, then `obtainIP` in a subprocess, then set `lease_ssid`). On failure: interactive → scan in a subprocess and show the network list; otherwise `_abortWifiConnection()`.
  - Returning `nil` from `turnOnWifi` means "pending" to `NetworkMgr:enableWifi()`; on failure the engine must call `_abortWifiConnection()` itself. `complete_callback` schedules KOReader's connectivity check (which broadcasts `NetworkConnected`).
  - `gen` counter: bumped by wrapped `disableWifi`/`_abortWifiConnection` and by each new attempt (latest wins). `subprocessCall` and `pollUntil` drop their callbacks when it changes.
  - Never use `ffiutil.readAllFromFD()` on subprocess pipes: Wi-Fi scripts spawn daemons that inherit the write end, so it would hang the UI thread forever. Use `drainPipe` (FIONREAD-based).
  - The engine shows no popups, except "Timed out" when a network tapped in the list fails to join.

## Settings

All in `G_reader_settings`, default-on via `nilOrTrue` / `flipNilOrTrue`: `wifiindicator_suppress_popups`, `wifiindicator_show_icon`, `wifiindicator_menu_icon`, `wifiindicator_nonblocking_wifi` (the engine's kill switch). When adding a setting, also add it to `WifiIndicator:deletePluginSettings()` and update the test that asserts the full key list.
