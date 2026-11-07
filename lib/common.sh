# Shared paths and helpers for install.sh and uninstall.sh.

PLUGIN_ID="ujo4eva.network"
PROFILE="ujo4eva-hotspot"
OMARCHY_CONFIG="$HOME/.config/omarchy"
PLUGIN_DIR="$OMARCHY_CONFIG/plugins/$PLUGIN_ID"
MENU_FILE="$OMARCHY_CONFIG/extensions/omarchy-menu.jsonc"
SHELL_JSON="$OMARCHY_CONFIG/shell.json"
BACKUP_ROOT="$OMARCHY_CONFIG/backups/omarchy-hotspot"
WARP_UNIT="hotspot-warp-bypass.service"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
UFW_COMMENT="omarchy-hotspot-installer"
BLOCK_BEGIN="// >>> omarchy-hotspot"
BLOCK_END="// <<< omarchy-hotspot"

say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Remove the block this repo manages, if present.
strip_menu_block() {
  local file=$1 tmp
  tmp=$(mktemp)
  awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" '
    index($0, begin) { skip = 1; next }
    skip && index($0, end) { skip = 0; next }
    !skip
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

# Insert the block before the file's closing brace. The menu parser only
# strips whole-line // comments and trailing commas, so give the last real
# entry a comma when it lacks one.
insert_menu_block() {
  local file=$1 block=$2 tmp
  tmp=$(mktemp)
  awk -v blockfile="$block" '
    { line[NR] = $0 }
    END {
      for (close_at = NR; close_at > 0; close_at--)
        if (line[close_at] ~ /^[[:space:]]*}[[:space:]]*$/) break
      if (close_at == 0) exit 1
      for (last = close_at - 1; last > 0; last--)
        if (line[last] !~ /^[[:space:]]*(\/\/.*)?$/) break
      if (last > 0 && line[last] !~ /[{,][[:space:]]*$/) line[last] = line[last] ","
      for (i = 1; i < close_at; i++) print line[i]
      while ((getline l < blockfile) > 0) print l
      for (i = close_at; i <= NR; i++) print line[i]
    }
  ' "$file" >"$tmp" || {
    rm -f "$tmp"
    fail "couldn't find the closing } in $file"
  }
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

swap_bar_widget() {
  local from=$1 to=$2 tmp
  tmp=$(mktemp)
  cp "$SHELL_JSON" "$SHELL_JSON.bak-omarchy-hotspot"
  jq --arg from "$from" --arg to "$to" \
    'walk(if type == "object" and .id? == $from then .id = $to else . end)' \
    "$SHELL_JSON" >"$tmp"
  cat "$tmp" >"$SHELL_JSON"
  rm -f "$tmp"
}

# The Wi-Fi interface the hotspot uses. Ask the plugin so the installer and the
# panel cannot drift apart on which device they mean.
hotspot_iface() {
  local plugin="$REPO/plugin/$PLUGIN_ID/hotspot.sh"
  [[ -f $plugin ]] || return 0
  bash "$plugin" iface 2>/dev/null || true
}

# The hotspot's own address on the shared /24; NetworkManager's default is
# 10.42.0.1 when no profile has configured one yet.
hotspot_gateway() {
  local addr
  addr=$(nmcli -g ipv4.addresses connection show "$PROFILE" 2>/dev/null | head -n 1 || true)
  addr=${addr%% *}
  if [[ -n $addr ]]; then
    printf '%s' "${addr%%/*}"
  else
    printf '10.42.0.1'
  fi
}

# The shared /24 the hotspot hands out, derived from its gateway address.
hotspot_subnet() {
  local gateway
  gateway=$(hotspot_gateway)
  printf '%s.0/24' "${gateway%.*}"
}

# The interface and subnet recorded in the unit a previous install wrote, so a
# re-install can clean up after an interface or address change.
installed_unit_scope() {
  local unit="$SYSTEMD_DIR/$WARP_UNIT"
  [[ -r $unit ]] || return 0
  sed -n 's/^# omarchy-hotspot-scope: iface=\([^ ]*\) subnet=\([^ ]*\)$/\1 \2/p' "$unit" |
    head -n 1
}

# Rules this installer owns carry UFW_COMMENT, so uninstall deletes only what
# it added and never an identical rule the user added by hand. Print the rule
# for a tag one argument per line, so add and delete always use the same spec.
hotspot_ufw_rule() {
  local tag=$1 iface=$2 subnet=$3
  case $tag in
    dhcp) printf '%s\n' allow in on "$iface" from any to any port 67 proto udp ;;
    dns-udp) printf '%s\n' allow in on "$iface" from "$subnet" to any port 53 proto udp ;;
    dns-tcp) printf '%s\n' allow in on "$iface" from "$subnet" to any port 53 proto tcp ;;
    forward) printf '%s\n' route allow in on "$iface" from "$subnet" ;;
  esac
}

hotspot_ufw_add_all() {
  local iface=$1 subnet=$2 tag spec
  for tag in dhcp dns-udp dns-tcp forward; do
    mapfile -t spec < <(hotspot_ufw_rule "$tag" "$iface" "$subnet")
    sudo ufw "${spec[@]}" comment "$UFW_COMMENT" >/dev/null ||
      warn "ufw: couldn't add the $tag rule for $iface"
  done
}

hotspot_ufw_delete_all() {
  local iface=$1 subnet=$2 tag spec
  [[ -n $subnet ]] || return 0
  for tag in dhcp dns-udp dns-tcp forward; do
    mapfile -t spec < <(hotspot_ufw_rule "$tag" "$iface" "$subnet")
    if [[ $tag == forward ]]; then
      sudo ufw --force route delete "${spec[@]:1}" comment "$UFW_COMMENT" >/dev/null 2>&1 || true
    else
      sudo ufw --force delete "${spec[@]}" comment "$UFW_COMMENT" >/dev/null 2>&1 || true
    fi
  done
}
