#!/bin/bash

# Undo install.sh: stop the hotspot, restore the stock network widget, remove
# the menu rows and the plugin. Pass --purge to also delete the saved hotspot
# network (name and password) from NetworkManager.

set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$REPO/lib/common.sh"

purge=0
[[ ${1:-} == --purge ]] && purge=1

if [[ -x $PLUGIN_DIR/hotspot.sh ]]; then
  bash "$PLUGIN_DIR/hotspot.sh" stop >/dev/null 2>&1 || true
fi

if [[ -f $SHELL_JSON ]] && command -v jq >/dev/null 2>&1 &&
  jq -e --arg id "$PLUGIN_ID" '.. | objects | select(.id? == $id)' "$SHELL_JSON" >/dev/null 2>&1; then
  swap_bar_widget "$PLUGIN_ID" omarchy.network
  say "Restored the stock network widget in $SHELL_JSON"
fi

if [[ -f $MENU_FILE ]]; then
  strip_menu_block "$MENU_FILE"
  say "Removed the Wi-Fi Hotspot rows from $MENU_FILE"
fi

if [[ -d $PLUGIN_DIR ]]; then
  rm -rf "$PLUGIN_DIR"
  say "Removed $PLUGIN_DIR"
fi

if ((purge)); then
  nmcli connection delete "$PROFILE" >/dev/null 2>&1 && say "Deleted the $PROFILE NetworkManager profile" || true
else
  say "Kept the saved hotspot settings; run with --purge to delete them"
fi

omarchy-shell -q shell rescanPlugins
omarchy-shell -q shell reloadConfig
