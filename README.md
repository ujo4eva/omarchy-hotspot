# omarchy-hotspot

Share your Omarchy machine's internet over Wi-Fi. This adds a hotspot section
to the network panel in the bar and a **Wi-Fi Hotspot** toggle to the Omarchy
menu.

Omarchy doesn't ship this yet. It's proposed upstream in
[omacom/omarchy#7435](https://github.com/omacom/omarchy/pull/7435). Until that
lands, this repo installs it as a user plugin, so it doesn't touch Omarchy's
own files.

## Requirements

- An Omarchy release with the Quickshell bar (`omarchy-shell` exists)
- NetworkManager, which current Omarchy uses by default
- A Wi-Fi card that supports AP mode. Check with `iw list | grep -A10 'interface modes'`
  and look for `* AP`.

## Install

```bash
git clone https://github.com/ujo4eva/omarchy-hotspot.git
cd omarchy-hotspot
./install.sh
```

The installer:

1. copies the `ujo4eva.network` plugin to `~/.config/omarchy/plugins/`
2. adds the Wi-Fi Hotspot rows to `~/.config/omarchy/extensions/omarchy-menu.jsonc`,
   between `// >>> omarchy-hotspot` markers
3. swaps the stock network widget for this one in `~/.config/omarchy/shell.json`
   (it saves the old file as `shell.json.bak-omarchy-hotspot`)

It installs `iw` with pacman if it's missing. You can run it again to update:

```bash
git pull && ./install.sh
```

## Use

Click the network icon in the bar and open the hotspot section. Set a network
name and a password, or generate one, and pick a band. Then turn it on. The
panel shows a QR code people can scan to join, plus the list of connected
devices, which you can give names.

You can also toggle it from **Omarchy menu > Trigger > Toggle > Wi-Fi Hotspot**,
or from a terminal:

```bash
~/.config/omarchy/plugins/ujo4eva.network/hotspot.sh status
~/.config/omarchy/plugins/ujo4eva.network/hotspot.sh toggle
```

Most Wi-Fi cards can't host a hotspot while they're also connected to another
Wi-Fi network on a different channel. It's most reliable when your internet
comes from Ethernet or a USB-tethered phone.

## Uninstall

```bash
./uninstall.sh          # keeps the saved hotspot name and password
./uninstall.sh --purge  # also deletes them from NetworkManager
```

## Tests

```bash
bash tests/hotspot-test.sh
```

The tests stub `nmcli`, `iw` and the other system commands, so they never
change your real network.
