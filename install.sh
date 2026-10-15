#!/bin/bash

# Install the Wi-Fi hotspot network panel (ujo4eva.network) for Omarchy:
#   1. copy the plugin into ~/.config/omarchy/plugins/
#   2. add the "Wi-Fi Hotspot" rows to ~/.config/omarchy/extensions/omarchy-menu.jsonc
#   3. swap the stock network bar widget for this one in ~/.config/omarchy/shell.json
# Safe to re-run: it replaces its own files and its own menu block only.

set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$REPO/lib/common.sh"

need() { command -v "$1" >/dev/null 2>&1; }

need omarchy-shell || fail "omarchy-shell not found; this needs an Omarchy release with the Quickshell bar"
need nmcli || fail "nmcli not found; the hotspot is driven by NetworkManager"
need jq || fail "jq not found (sudo pacman -S jq)"
systemctl is-active --quiet NetworkManager || warn "NetworkManager is not running; the hotspot will not start until it is"

if ! need iw; then
  say "Installing iw (used to check that your Wi-Fi card can host an access point)"
  sudo pacman -S --needed iw
fi

if ! need dnsmasq; then
  say "Installing dnsmasq (NetworkManager's shared mode needs it for DHCP)"
  sudo pacman -S --needed dnsmasq
fi

# Capture first: under pipefail, grep -q exiting early SIGPIPEs iw and fails the pipe.
phy_info=$(iw phy 2>/dev/null || true)
if ! grep -Eq '^[[:space:]]*\*[[:space:]]*AP[[:space:]]*$' <<<"$phy_info"; then
  warn "no Wi-Fi adapter here reports AP mode; the panel installs, but the hotspot toggle stays hidden"
fi

# 1. Plugin. Back up a differing copy outside plugins/ so the shell never loads
# two plugins with the same id.
if [[ -d $PLUGIN_DIR ]] && ! diff -rq "$REPO/plugin/$PLUGIN_ID" "$PLUGIN_DIR" >/dev/null 2>&1; then
  backup="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"
  cp -r "$PLUGIN_DIR" "$backup/"
  say "Backed up your existing $PLUGIN_ID to $backup"
fi
mkdir -p "$(dirname "$PLUGIN_DIR")"
rm -rf "$PLUGIN_DIR"
cp -r "$REPO/plugin/$PLUGIN_ID" "$PLUGIN_DIR"
chmod +x "$PLUGIN_DIR/hotspot.sh"
say "Installed plugin to $PLUGIN_DIR"

# 2. Menu rows.
mkdir -p "$(dirname "$MENU_FILE")"
[[ -s $MENU_FILE ]] || printf '{\n}\n' >"$MENU_FILE"
strip_menu_block "$MENU_FILE"
if grep -Eq '"(trigger\.toggle\.wifi-hotspot|setup\.network\.hotspot)"' "$MENU_FILE"; then
  warn "your menu file already defines the hotspot rows by hand; leaving them as they are"
else
  insert_menu_block "$MENU_FILE" "$REPO/menu/hotspot.jsonc"
  say "Added Wi-Fi Hotspot rows to $MENU_FILE"
fi

# 3. Bar widget.
if [[ -f $SHELL_JSON ]] && jq -e '.. | objects | select(.id? == "omarchy.network")' "$SHELL_JSON" >/dev/null 2>&1; then
  swap_bar_widget omarchy.network "$PLUGIN_ID"
  say "Replaced the stock network widget with $PLUGIN_ID in $SHELL_JSON"
elif [[ -f $SHELL_JSON ]] && jq -e --arg id "$PLUGIN_ID" '.. | objects | select(.id? == $id)' "$SHELL_JSON" >/dev/null 2>&1; then
  say "Bar already uses $PLUGIN_ID"
else
  warn "couldn't find the network widget in $SHELL_JSON; add \"My Network\" from the bar settings yourself"
fi

omarchy-shell -q shell rescanPlugins
omarchy-shell -q shell reloadConfig

cat <<EOF

Done. Click the network icon in the bar and open the Hotspot section, or use
Omarchy menu > Trigger > Toggle > Wi-Fi Hotspot.

Note: most Wi-Fi cards can't host a hotspot while also connected to another
Wi-Fi network on a different channel, so share an Ethernet (or USB tether)
connection for the most reliable setup.
EOF
