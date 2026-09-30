# Wi-Fi status & connect

A KOReader plugin for Kobo that keeps Wi-Fi out of your way while you read.

Based on [wifiindicator.koplugin](https://github.com/asxelot/wifiindicator.koplugin)
and [koreader-nonblocking-wifi](https://github.com/asxelot/koreader-nonblocking-wifi)
by Eugene Ryzhkov ([asxelot](https://github.com/asxelot)). This is a modified
version, maintained separately since September 2026.

## Why

Out of the box, KOReader on Kobo:

- freezes the screen while Wi-Fi connects (5 seconds or more on a Clara BW),
- shows a popup at every step of connecting, and
- only reconnects on its own to networks the Kobo itself knows.

This plugin fixes all three.

## Features

- **No freezing.** Wi-Fi connects in the background, so you can keep reading.
- **Saved networks reconnect.** Networks you saved in KOReader reconnect after
  sleep, even if the Kobo itself doesn't know them.
- **No popups.** Wi-Fi messages are replaced by a small status icon.
- **Status at a glance.** An icon in the top-left corner and in the menu bar.
  Tap the menu-bar icon to turn Wi-Fi on or off.
- **Tidier network list.** Dual-band routers show up once instead of twice.

## Status icons

| Icon | Meaning |
|---|---|
| Faint waves | Wi-Fi off |
| Dot only | Wi-Fi on, not connected (menu bar only) |
| Half the waves | Connecting |
| Full waves | Connected |
| Warning triangle | Something went wrong |

The corner icon stays up while connecting, then shows the result for a few
seconds. If no saved network is in range when you turn Wi-Fi on, the network
list opens so you can pick one.

## Settings

Go to **Menu → Network → Wi-Fi status & connect**:

- **Show network list**: scan now and pick a network. Turns Wi-Fi on if needed.
- **Connect in the background**: turn off to use KOReader's standard connect,
  which freezes the screen.
- **Hide Wi-Fi popups**
- **Show Wi-Fi status in corner**
- **Show Wi-Fi status in menu bar**

To edit or forget a saved network, tap **edit** on its row in the network
list. If you're connected to it, tap **disconnect** first.

## Install

1. Download `wifistatus.koplugin.zip` from the [latest release](../../releases/latest).
2. Unzip it and copy the `wifistatus.koplugin` folder into
   `.adds/koreader/plugins/` on your Kobo. The `.adds` folder is hidden.
3. Restart KOReader.

**Upgrading from `wifiindicator.koplugin`** (this plugin's old name, or the
original plugin)? Delete that folder first. Your settings are kept.

## Updating

[Storefront](https://github.com/ultimatejimmy/storefront.koplugin) lists this
plugin and can update it. Use the entry **isaiahaguilera/wifistatus.koplugin**.
The similarly named `asxelot/wifiindicator.koplugin` is the original plugin
and would replace this one.

You can also download the latest release and repeat the install steps.

## Compatibility

- Made for Kobo. Tested on a Kobo Clara BW with KOReader v2026.07.1.
- On other devices, background connecting stays off. Hiding popups and the
  status icons still work.
- If you also use the koreader-nonblocking-wifi patch, the patch takes over
  connecting. You only need one of them.
- Popups are recognized by KOReader's exact wording. If a KOReader update
  rewords one, that popup may show again until this plugin is updated.

## Development

Run the tests from the repo root with [LuaJIT](https://luajit.org):

```sh
luajit test/test_main.lua main.lua
luajit test/test_wificonnect.lua
luajit test/test_engine.lua
```

To release, bump `version` in `_meta.lua`, commit, then push a matching tag:

```sh
git tag v2.0.1 && git push origin main v2.0.1
```

GitHub Actions runs the tests and publishes the release with
`wifistatus.koplugin.zip` attached.

Design notes: [docs/plan-wpa-handoff.md](docs/plan-wpa-handoff.md).
Project history and working notes: [CLAUDE.md](CLAUDE.md).

## License

GPL-3.0. See [LICENSE](LICENSE).
