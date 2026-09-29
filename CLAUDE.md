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
- **Active work: branch `wpa-handoff`.** Follow **`docs/plan-wpa-handoff.md`** (read it first). It replaces `nbwifi.lua` with `wificonnect.lua`, which hands KOReader's saved networks to wpa_supplicant and lets it pick. It also makes joining from the network list non-blocking and adds a status presenter in `main.lua` with a "connecting" icon that stays up. Merge into `main` only after the on-device comparison in the plan. Phase 0 is done; the phase in progress is recorded in the *Session log*.

## Open threads

- **Roadmap after the branch (approved 2026-09-28):** (a) on-device popup audit: add any KOReader Wi-Fi popup that still gets through to `INTERCEPTED_MESSAGES`, with tests; (b) a small script that diffs KOReader's Wi-Fi files between two releases (the files checked for v2026.07.1: `platform/kobo/{enable,disable}-wifi.sh`, `obtain-ip.sh`, `restore-wifi-async.sh`, `frontend/device/kobo/device.lua`, `frontend/ui/network/{manager,wpa_supplicant,networklistener}.lua`, `frontend/ui/widget/networksetting.lua`); (c) README/housekeeping: point install links at the fork, drop the upstream-patch coordination.
- **Future discussion (user-requested, not scheduled):** other status icon options and customizing the notification. See *Project context*.
- **"Authenticating…" TODO (deferred 2026-09-28):** on `main`, `nbwifi.lua` shows `_("Authenticating…")`, which isn't in `INTERCEPTED_MESSAGES`. The `wpa-handoff` engine makes this moot (no engine popups). Only fix it on `main` if the branch is abandoned.
- **Known gap on `main`:** joining from KOReader's network list (`frontend/ui/widget/networksetting.lua` → `authenticateNetwork` + `obtainIP`) still freezes for up to about 60 s and shows popups. Addressed in the plan (phase 4).
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
- `[project, 2026-09-28]` **Redesign plan approved.** The user approved planning the "hand saved networks to wpa_supplicant" engine on a new branch, `wpa-handoff`, merged into `main` only if on-device testing shows it works better. Plan: `docs/plan-wpa-handoff.md`. **Why:** fixes the split between the Kobo OS's and KOReader's network lists while keeping the UI responsive, with less code. **How to apply:** follow the plan's phases; don't merge without the on-device comparison.
- `[project, 2026-09-28]` **Future topic: icon options and notification customization.** The user will want to discuss different status icon options and customizing the notification (the corner toast). It isn't scheduled; raise it after the `wpa-handoff` branch or when the user brings it up. **Why:** they want the status display to fit their taste, not just upstream's defaults. **How to apply:** keep every presentation choice (icons, position, size, timeouts) in the single status presenter in `main.lua`; the engine only reports states (`connecting` / `connected` / `failed` / `idle`).
- `[feedback, 2026-09-28]` Mirror every project memory into this file and keep it working as a handoff doc (see *Rules for Claude*). **Why:** the user wants any future LLM session to recover the full context from the repo alone, with no prior memory. **How to apply:** after any memory write, update this section; before stopping, update *Current state*, *Open threads* and *Session log*.

## Session log

Newest first. One entry per working session: what changed, what was decided, what's next.

- **2026-09-28:** Ran `/init` and wrote this file (tests, architecture, settings). The user then made it a repo rule that memories are mirrored here and that this file stays a working handoff doc; it was restructured accordingly. Found that the repo is a fork with upstream-only history. The user set the fork's goals (see *Project context*) and asked how complex the plugin is. Assessed it: `main.lua` is simple (about 230 code lines); `nbwifi.lua` is the complex part (about 475 code lines, an async state machine that depends on KOReader's `NetworkMgr` internals). The review turned up the possible "Authenticating…" popup and code that never runs on Kobo. The user deferred the popup fix as a TODO and had the emulator test code removed from `nbwifi.lua` (not run through the tests, since no Lua interpreter is installed). The user confirmed a freeze of 5+ seconds on connect on their Clara BW, the reason they forked, and that it happens on stock KOReader. Read koreader/koreader#14790 and #14716 plus KOReader's Kobo Wi-Fi source; findings are under *Project context*. Proposed letting wpa_supplicant choose the network and explained it in plain terms. The user approved it for a branch. Checked a few more KOReader details (`disable-wifi.sh` terminates wpa_supplicant; how the wake-restore callers work; the lj-wpaclient API) and wrote `docs/plan-wpa-handoff.md`. Then the user reported KOReader v2026.07.1 (its Wi-Fi source matches master for our purposes), confirmed `main` works on the device, and installed LuaJIT (all 29 tests pass). They asked whether "good enough" is enough, given the aim of clean and lean. Found that joining from the network list still freezes and shows popups even with the plugin. Proposed a roadmap aimed at "best version of the mission", and the user approved it. They also flagged a future talk about icon options and notification customization. Folded the network-list fix and the status presenter into the plan, committed the `main` work, and created branch `wpa-handoff`.

---

## What this is

A KOReader plugin (Lua 5.1 / LuaJIT) that suppresses Wi-Fi lifecycle popups, shows a transient corner icon and a tappable menu-bar Wi-Fi icon instead, and bundles a non-blocking Wi-Fi connect engine. Only `main.lua`, `nbwifi.lua` and `_meta.lua` ship at runtime; there is no build step. Users install by copying the folder into `koreader/plugins/` (the release zip must expand to a folder named `wifiindicator.koplugin/`).

## Tests

```sh
luajit test/test_main.lua main.lua
```

- Run from the **repo root**: `main.lua` does `require("nbwifi")`, which only resolves via `./?.lua`.
- There's no test framework and no single-test selection: it's one script of `check(cond, label)` calls printing PASS/FAIL, exiting non-zero on any failure.
- The harness stubs every KOReader module via `package.preload` and a global `G_reader_settings`. When `main.lua` gains a new `require`, add a matching stub or the harness breaks.
- The `device` / `ui/network/manager` stubs deliberately make `nbwifi.lua` bail out early (not SDL, not Kindle, no `wpa_supplicant`), so the engine is **not** covered by this harness. On `main` the only on-device-free check for it is a syntax check: `luajit -bl nbwifi.lua /dev/null`. Its upstream emulator harness (`NBWIFI_TEST=1` on the SDL emulator) was removed in this fork on 2026-09-28, so the engine can only be tested on a real device. The old version is in git history before that change (e.g. commit `87f575c`).

## Architecture

KOReader has no hooks for this, so everything works by **monkey-patching KOReader globals at module load time**, not in `WifiIndicator:init()`.

- **Load-once guards.** KOReader instantiates the plugin twice (FileManager and ReaderUI), and the module file may be loaded more than once. Every patch stores the original under a `_wifiindicator_orig_*` field on the patched table and only wraps if that field is absent. Shared state (the corner icon frame) is module-level for the same reason. Preserve this pattern for any new patch; the test "double plugin load still injects exactly one icon" guards it.
- **`main.lua`**
  - Wraps `UIManager.show` to drop `InfoMessage`s whose `text` matches `INTERCEPTED_MESSAGES`. These entries must be the *exact* source strings from KOReader's NetworkMgr/NetworkListener/NetworkSetting, wrapped in `_()` so gettext resolves them to the same translation as upstream KOReader; `msgToPattern` turns `%1` into a wildcard and anchors the pattern. If KOReader changes its wording, update this list.
  - Wraps `TouchMenu.init` (injects an `IconButton` and a span at the head of `menu.device_info`) and `TouchMenu.updateItems` (refreshes the icon from `NetworkMgr:isConnected()`/`isWifiOn()`). Tapping broadcasts `ToggleWifi`.
  - `onNetworkConnected`/`onNetworkDisconnected` show the corner toast and must **not** return `true` (other listeners need the events).
- **`nbwifi.lua`** is a bundled copy of the [koreader-nonblocking-wifi](https://github.com/asxelot/koreader-nonblocking-wifi) user patch. It replaces `NetworkMgr:reconnectOrShowNetworkMenu` (and `turnOnWifi` on wpa_supplicant devices) with an async state machine: blocking steps (hardware enable, scan, DHCP) run in forked subprocesses, and association is polled every 250 ms via `UIManager:scheduleIn`. Key invariants, also documented in its header and comments:
  - Returns `{ installed = bool }`; `main.lua` only shows the "Non-blocking Wi-Fi connect" menu toggle when installed.
  - Coordinates with the standalone user patch through `NetworkMgr._nbwifi_installed` (user patches load first and win; the bundled copy then backs off).
  - Returning `nil` from `turnOnWifi` means "pending" to `NetworkMgr:enableWifi()`; on failure the engine must call `_abortWifiConnection()` itself.
  - A `gen` counter, bumped by wrapped `disableWifi`/`_abortWifiConnection`, invalidates in-flight async steps. Check `gen ~= my_gen` in every callback.
  - Never use `ffiutil.readAllFromFD()` on subprocess pipes: Wi-Fi scripts spawn daemons that inherit the write end, so it would hang the UI thread forever. Use `drainPipe` (FIONREAD-based).
  - Platform backends: real `wpa_supplicant` (Kobo & co), and Kindle lipc (only the scan is forked; wifid handles auth and DHCP).
  - The engine's own "Turning on Wi-Fi…" popup is itself swallowed by `main.lua`'s `UIManager.show` filter.

## Settings

All in `G_reader_settings`, default-on via `nilOrTrue` / `flipNilOrTrue`: `wifiindicator_suppress_popups`, `wifiindicator_show_icon`, `wifiindicator_menu_icon`, `wifiindicator_nonblocking_wifi`. When adding a setting, also add it to `WifiIndicator:deletePluginSettings()` and update the test that asserts the full key list.
