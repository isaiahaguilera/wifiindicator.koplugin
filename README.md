# Wi-Fi status & connect

A KOReader plugin for Kobo and Kindle that keeps Wi-Fi out of your way while you read.

Based on [wifiindicator.koplugin](https://github.com/asxelot/wifiindicator.koplugin)
and [koreader-nonblocking-wifi](https://github.com/asxelot/koreader-nonblocking-wifi)
by Eugene Ryzhkov ([asxelot](https://github.com/asxelot)). This is a modified
version, maintained separately since September 2026.

## Why

Out of the box, KOReader:

- freezes the screen while Wi-Fi connects (5 seconds or more on a Kobo Clara
  BW; up to 20 seconds on a Kindle while it scans for networks),
- shows a popup at every step of connecting, and
- on Kobo, only reconnects on its own to networks the Kobo itself knows.

This plugin fixes all three.

## Features

- **No freezing.** Wi-Fi connects in the background, so you can keep reading.
- **Saved networks reconnect (Kobo).** Networks you saved in KOReader reconnect
  after sleep, even if the Kobo itself doesn't know them. Kindles already do
  this on their own.
- **No popups.** Wi-Fi messages are replaced by a small status icon.
- **Status at a glance.** An icon in the top-left corner and in the menu bar.
  Tap the menu-bar icon to turn Wi-Fi on or off.
- **Tidier network list.** Dual-band routers show up once instead of twice.

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
2. Unzip it and copy the `wifistatus.koplugin` folder into KOReader's
   `plugins` folder: `.adds/koreader/plugins/` on a Kobo (`.adds` is hidden),
   `koreader/plugins/` on a Kindle.
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

- Made for Kobo and Kindle. Tested with KOReader v2026.07.1 on a Kobo Clara BW
  and a Kindle on firmware 5.19.6.
- On other devices, only hiding popups and the status icons are active.
  KOReader's own Wi-Fi connecting is left as is.
- If you also use the koreader-nonblocking-wifi patch, the patch takes over
  connecting. You only need one of them.
- Popups are recognized by KOReader's exact wording. If a KOReader update
  rewords one, that popup may show again until this plugin is updated.

## License

GPL-3.0. See [LICENSE](LICENSE).
