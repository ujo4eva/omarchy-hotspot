#!/bin/bash

# Install the Wi-Fi hotspot network panel (ujo4eva.network) for Omarchy:
#   1. open the firewall for hotspot DHCP/DNS/forwarding and keep client
#      traffic out of full-tunnel VPNs
#   2. copy the plugin into ~/.config/omarchy/plugins/
#   3. add the "Wi-Fi Hotspot" rows to ~/.config/omarchy/extensions/omarchy-menu.jsonc
#   4. swap the stock network bar widget for this one in ~/.config/omarchy/shell.json
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

# 1. Host plumbing. NetworkManager's shared mode runs DHCP and NATs, but two
# host-wide defaults still cut clients off on some machines: ufw drops forwarded
# traffic and sends DHCP (port 67) to its policy, and full-tunnel VPNs such as
# Cloudflare WARP route forwarded client packets into the tunnel. Open exactly
# what the hotspot needs, scoped to its own interface and subnet.
ap_iface=$(hotspot_iface)
if [[ -z $ap_iface ]]; then
  warn "couldn't find a Wi-Fi interface; skipped the firewall and VPN routing setup"
else
  subnet=$(hotspot_subnet)

  # A previous install records its interface and subnet in the unit. Remove
  # those rules first, so changing the Wi-Fi interface or address doesn't
  # strand rules that uninstall can no longer match.
  prev_iface="" prev_subnet=""
  read -r prev_iface prev_subnet <<<"$(installed_unit_scope)" || true
  if [[ -n $prev_iface && ($prev_iface != "$ap_iface" || $prev_subnet != "$subnet") ]]; then
    [[ -n $prev_subnet ]] || prev_subnet=$subnet
    if need ufw; then
      hotspot_ufw_delete_all "$prev_iface" "$prev_subnet"
      say "Removed the old ufw rules for $prev_iface"
    fi
    if [[ $prev_iface != "$ap_iface" ]]; then
      sudo ip rule del iif "$prev_iface" lookup main priority 1 2>/dev/null || true
    fi
  fi

  if need ufw; then
    say "Opening ufw for hotspot clients on $ap_iface ($subnet)"
    # DHCP requests are broadcast, so that rule cannot be narrowed to the
    # subnet; DNS and forwarding are scoped to the clients.
    hotspot_ufw_add_all "$ap_iface" "$subnet"
  else
    say "ufw not installed; skipping firewall rules"
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    warn "firewalld is active; add equivalent DHCP, DNS and forwarding rules for $ap_iface"
  fi

  say "Keeping hotspot traffic out of full-tunnel VPNs"
  sudo ip rule add iif "$ap_iface" lookup main priority 1 2>/dev/null || true
  unit_tmp=$(mktemp)
  sed -e "s|@IFACE@|$ap_iface|g" -e "s|@SUBNET@|$subnet|g" "$REPO/lib/$WARP_UNIT.in" >"$unit_tmp"
  sudo install -m 0644 "$unit_tmp" "$SYSTEMD_DIR/$WARP_UNIT"
  rm -f "$unit_tmp"
  sudo systemctl daemon-reload
  # enable --now leaves an already-active unit alone, so restart it explicitly
  # to replace the policy rule when the interface or subnet changed.
  sudo systemctl enable "$WARP_UNIT" >/dev/null 2>&1 || true
  sudo systemctl restart "$WARP_UNIT" >/dev/null 2>&1 ||
    warn "couldn't restart $WARP_UNIT; the rule is active for this boot only"
fi

# 2. Plugin. Back up a differing copy outside plugins/ so the shell never loads
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

# 3. Menu rows.
mkdir -p "$(dirname "$MENU_FILE")"
[[ -s $MENU_FILE ]] || printf '{\n}\n' >"$MENU_FILE"
strip_menu_block "$MENU_FILE"
if grep -Eq '"(trigger\.toggle\.wifi-hotspot|setup\.network\.hotspot)"' "$MENU_FILE"; then
  warn "your menu file already defines the hotspot rows by hand; leaving them as they are"
else
  insert_menu_block "$MENU_FILE" "$REPO/menu/hotspot.jsonc"
  say "Added Wi-Fi Hotspot rows to $MENU_FILE"
fi

# 4. Bar widget.
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
