#!/bin/bash

# omarchy:summary=Manage a Wi-Fi access point (hotspot) that shares the machine's internet
# omarchy:group=network
# omarchy:args=<status|start|stop|toggle|qr|apply|alias-set|alias-remove|generate-password>
# omarchy:examples=hotspot.sh status | hotspot.sh toggle | hotspot.sh apply MyWifi 2.4 5 wpa3 | hotspot.sh start MyWifi 2.4 unlimited

# User-owned companion script for the cloned omarchy.network panel
# (ujo4eva.network). Drives NetworkManager's shared-mode AP profile so other
# devices can join this machine and route through its upstream connection.

set -euo pipefail

PROFILE="ujo4eva-hotspot"

fail() {
  echo "hotspot: $*" >&2
  exit 1
}

nm_get() {
  LC_ALL=C nmcli -e no -g "$@" 2>/dev/null || true
}

nm_band_for() {
  case "$1" in
    2.4) echo "bg" ;;
    5) echo "a" ;;
    6) echo "6GHz" ;;
    *) return 1 ;;
  esac
}

band_from_nm() {
  case "$1" in
    bg) echo "2.4" ;;
    a) echo "5" ;;
    6GHz) echo "6" ;;
    *) echo "2.4" ;;
  esac
}

# NetworkManager quietly turns a plain wpa-psk AP into WPA2/WPA3 transition
# mode (it adds SAE) whenever the card supports SAE. Some older Android
# clients then upgrade to SAE, fail before associating, and never show up in
# the AP's log. So the security is explicit: "wpa2" pins PSK by disabling PMF
# (SAE cannot run without it); "wpa3" is SAE only, for owners whose devices
# all support it. Protocol and ciphers are pinned to RSN/CCMP: without them
# wpa_supplicant's AP mode cannot build the beacon's RSN element for SAE alone
# ("Could not generate WPA IE") and NetworkManager times out.
nm_security_args() {
  local ciphers="wifi-sec.proto rsn wifi-sec.pairwise ccmp wifi-sec.group ccmp"
  case "$1" in
    wpa2) echo "wifi-sec.key-mgmt wpa-psk wifi-sec.pmf disable $ciphers" ;;
    wpa3) echo "wifi-sec.key-mgmt sae wifi-sec.pmf required $ciphers" ;;
    *) return 1 ;;
  esac
}

# Channels the PHY can actually start an AP on. Skip disabled, no-IR (can't
# initiate radiation), and DFS/radar — channel 36 is no-IR on many Intel
# cards, which is why a 5 GHz AP times out if we pin it blindly.
usable_channel_for() {
  local want=$1
  iw phy 2>/dev/null | awk -v want="$want" '
    /Band 1:/ { band="2.4" }
    /Band 2:/ { band="5" }
    /Band 3:/ { band="6" }
    /Band 4:/ { band="6" }
    band == want && /MHz \[/ && $0 !~ /disabled/ && $0 !~ /no IR/ && $0 !~ /radar detection/ {
      if (match($0, /\[[0-9]+\]/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    }
  '
}

ap_bands() {
  local bands="" b
  for b in 2.4 5 6; do
    [[ -n $(usable_channel_for "$b") ]] || continue
    if [[ -n $bands ]]; then
      bands+=",$b"
    else
      bands=$b
    fi
  done
  printf '%s' "$bands"
}

# NetworkManager auto-picks the AP channel and tends to land on 12/13 for
# 2.4 GHz, which many phones refuse to join - they only support channels
# 1-11. Prefer the first PHY-usable channel; fall back to a safe default
# (UNII-3 149 rather than 36, which is often no-IR).
nm_channel_for() {
  local ch
  ch=$(usable_channel_for "$1")
  if [[ -n $ch ]]; then
    echo "$ch"
    return
  fi
  case "$1" in
    2.4) echo "6" ;;
    5) echo "149" ;;
    6) echo "" ;;
  esac
}

# Any wireless PHY that can run AP mode? Capture `iw phy` before matching:
# piping it into grep -q under pipefail fails whenever grep exits on the first
# match and iw dies of SIGPIPE writing the rest. One retry still covers a
# genuine bad poll while the radio rescans.
phy_has_ap() {
  local info
  info=$(iw phy 2>/dev/null) || true
  grep -Eq '^[[:space:]]*\*[[:space:]]*AP[[:space:]]*$' <<<"$info"
}

ap_capable() {
  phy_has_ap && return 0
  sleep 0.05
  phy_has_ap
}

first_wifi_device() {
  LC_ALL=C nmcli -t -f DEVICE,TYPE device status 2>/dev/null |
    awk -F: '$2 == "wifi" && $1 !~ /^p2p-dev-/ { print $1; exit }'
}

wifi_devices() {
  LC_ALL=C nmcli -t -f DEVICE,TYPE device status 2>/dev/null |
    awk -F: '$2 == "wifi" && $1 !~ /^p2p-dev-/ { print $1 }'
}

profile_configured() {
  [[ -n $(nm_get NAME connection show 2>/dev/null | grep -x "$PROFILE") ]]
}

profile_active() {
  [[ -n $(LC_ALL=C nmcli -t -f NAME connection show --active 2>/dev/null | grep -x "$PROFILE") ]]
}

# The device the profile runs on when active, else the first wifi device.
ap_iface() {
  local dev
  dev=$(nm_get GENERAL.DEVICE connection show "$PROFILE" 2>/dev/null | head -n 1)
  if [[ -n $dev && $dev != "--" ]]; then
    echo "$dev"
  else
    first_wifi_device
  fi
}

# The NetworkManager profile is the single source of truth for the hotspot
# credentials (SSID, band, passphrase). Nothing is stored in a sidecar config
# file, so there is no plaintext secret outside the root-owned profile.
# `apply` writes the profile without starting the AP; `start` writes it and
# brings the AP up.

generate_password() {
  tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 10 || true
  echo
}

# Default SSID when nothing has been configured yet. First word of the host
# name, uppercased, plus " Hotspot".
default_ssid() {
  local host
  host=$(hostname 2>/dev/null || echo "pc")
  printf '%s' "${host^^} Hotspot"
}

profile_ssid() {
  nm_get 802-11-wireless.ssid connection show "$PROFILE"
}

profile_band() {
  band_from_nm "$(nm_get 802-11-wireless.band connection show "$PROFILE")"
}

# Anything but SAE reads as wpa2, including an older profile still in
# transition mode; the next apply pins it.
profile_security() {
  case "$(nm_get 802-11-wireless-security.key-mgmt connection show "$PROFILE")" in
    sae) echo "wpa3" ;;
    *) echo "wpa2" ;;
  esac
}

profile_secret() {
  nmcli --show-secrets --escape no --get-values 802-11-wireless-security.psk \
    connection show "$PROFILE" 2>/dev/null | head -n 1 || true
}

# Participant limit, read back from the profile's shared DHCP range
# (e.g. "10.42.0.2,10.42.0.6" -> 5). Empty when unlimited / unparseable.
profile_max_clients() {
  local range start end s e
  range=$(nm_get ipv4.shared-dhcp-range connection show "$PROFILE")
  [[ $range == *,* ]] || return 0
  start=${range%,*}
  end=${range#*,}
  [[ ${start%.*} == "${end%.*}" ]] || return 0
  s=${start##*.}
  e=${end##*.}
  if [[ $s =~ ^[0-9]+$ && $e =~ ^[0-9]+$ ]] && ((e > s)); then
    echo $((e - s + 1))
  fi
}

# First three octets of the shared subnet. Defaults to NetworkManager's
# 10.42.0.0/24; honors a custom /24 already on the profile.
shared_base() {
  local addr prefix base
  addr=$(nm_get ipv4.addresses connection show "$PROFILE")
  if [[ -z $addr ]]; then
    echo "10.42.0"
    return 0
  fi
  addr=${addr%% *}
  prefix=${addr#*/}
  addr=${addr%%/*}
  [[ $prefix == 24 ]] || fail "custom hotspot subnet '$addr/$prefix' is not /24 (clear ipv4.addresses first)"
  base=${addr%.*}
  [[ $base != "$addr" ]] || fail "cannot parse hotspot subnet '$addr'"
  echo "$base"
}

# DHCP range handing out exactly N leases: <base>.2 .. <base>.(N+1)
# (.1 is the gateway). Users beyond the Nth associate but get no address.
dhcp_range_for() {
  local n=$1 base
  [[ $n =~ ^[0-9]+$ ]] && ((n >= 1 && n <= 253)) ||
    fail "participant limit must be 1-253"
  base=$(shared_base)
  echo "$base.2,$base.$((n + 1))"
}

upstream_type() {
  local dev
  dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
  [[ -n $dev ]] || { echo "none"; return; }
  if [[ -d /sys/class/net/$dev/wireless ]]; then echo "wifi"
  elif [[ -d /sys/class/net/$dev/bridge ]]; then echo "bridge"
  else echo "ethernet"; fi
}

participant_alias_file() {
  printf '%s/omarchy/ujo4eva.network/participant-aliases.tsv' "${XDG_CONFIG_HOME:-${HOME:?}/.config}"
}

normalize_participant_mac() {
  local mac=${1,,}
  [[ $mac =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]] || return 1
  printf '%s' "$mac"
}

trim_participant_alias() {
  local alias=$1
  alias=${alias#"${alias%%[![:space:]]*}"}
  alias=${alias%"${alias##*[![:space:]]}"}
  printf '%s' "$alias"
}

valid_participant_alias() {
  local alias=$1
  [[ -n $alias && ${#alias} -le 64 && $alias != *[[:cntrl:]]* ]]
}

set_participant_alias() {
  local mac alias file tmp existing_mac existing_alias
  mac=$(normalize_participant_mac "${1:-}") || fail "invalid participant MAC"
  IFS= read -r alias || true
  alias=$(trim_participant_alias "$alias")
  valid_participant_alias "$alias" || fail "participant alias must be 1-64 characters without control characters"
  file=$(participant_alias_file)
  umask 077
  mkdir -p "${file%/*}" || fail "could not create participant alias directory"
  tmp=$(mktemp "${file}.XXXXXX") || fail "could not create participant alias file"
  if [[ -f $file ]]; then
    while IFS=$'\t' read -r existing_mac existing_alias; do
      existing_mac=${existing_mac,,}
      valid_participant_alias "$existing_alias" || continue
      [[ $existing_mac =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]] || continue
      [[ $existing_mac == "$mac" ]] && continue
      printf '%s\t%s\n' "$existing_mac" "$existing_alias" >>"$tmp"
    done <"$file"
  fi
  printf '%s\t%s\n' "$mac" "$alias" >>"$tmp"
  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    fail "could not save participant alias"
  fi
}

remove_participant_alias() {
  local mac file tmp existing_mac existing_alias
  mac=$(normalize_participant_mac "${1:-}") || fail "invalid participant MAC"
  file=$(participant_alias_file)
  [[ -f $file ]] || return 0
  umask 077
  tmp=$(mktemp "${file}.XXXXXX") || fail "could not create participant alias file"
  while IFS=$'\t' read -r existing_mac existing_alias; do
    existing_mac=${existing_mac,,}
    valid_participant_alias "$existing_alias" || continue
    [[ $existing_mac =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]] || continue
    [[ $existing_mac == "$mac" ]] && continue
    printf '%s\t%s\n' "$existing_mac" "$existing_alias" >>"$tmp"
  done <"$file"
  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    fail "could not remove participant alias"
  fi
}

station_list() {
  local iface=$1 mac signal
  [[ -n $iface ]] || return 0
  if ! command -v iw >/dev/null 2>&1; then return 0; fi
  local dump block cache_dir cache_file alias_file
  local -A client_hostnames=() client_ips=() client_aliases=()
  local -a station_rows=()
  cache_dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  cache_file="$cache_dir/ujo4eva-network-${iface}-participant-hostnames-v2.tsv"
  if [[ -r $cache_file ]]; then
    local cached_mac cached_hostname
    while IFS=$'\t' read -r cached_mac cached_hostname; do
      [[ -n $cached_mac && -n $cached_hostname && $cached_hostname != "*" ]] || continue
      client_hostnames["${cached_mac,,}"]=$cached_hostname
    done <"$cache_file"
  fi
  alias_file=$(participant_alias_file)
  if [[ -r $alias_file ]]; then
    local alias_mac alias_name
    while IFS=$'\t' read -r alias_mac alias_name; do
      alias_mac=${alias_mac,,}
      valid_participant_alias "$alias_name" || continue
      [[ $alias_mac =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]] || continue
      client_aliases["$alias_mac"]=$alias_name
    done <"$alias_file"
  fi
  dump=$(iw dev "$iface" station dump 2>/dev/null) || return 0
  [[ -n $dump ]] || return 0
  block=$(printf '%s\n' "$dump" | awk '/^Station / { if (seen) print ""; seen=1 } { printf "%s ", $0 }')
  [[ -n $block ]] || return 0
  local line needs_refresh=0
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    mac=$(awk '{ for (i = 1; i <= NF; i++) if ($i == "Station") { print $(i + 1); break } }' <<<"$line")
    signal=$(awk '{ for (i = 1; i <= NF; i++) if ($i == "signal:") { gsub(/[^0-9-]/, "", $(i + 1)); print $(i + 1); break } }' <<<"$line")
    [[ -n $mac ]] || continue
    station_rows+=("$mac"$'\t'"${signal:-0}")
    [[ -n ${client_hostnames["${mac,,}"]:-} ]] || needs_refresh=1
  done <<<"$block"
  if ((needs_refresh)) && command -v journalctl >/dev/null 2>&1; then
    local timestamp event lease_ip lease_mac lease_hostname lease_key
    while read -r timestamp event lease_ip lease_mac lease_hostname; do
      [[ $event == "DHCPACK($iface)" && -n $lease_ip && -n $lease_mac ]] || continue
      lease_key=${lease_mac,,}
      client_ips["$lease_key"]=$lease_ip
      if [[ -n $lease_hostname && $lease_hostname != "*" ]]; then
        client_hostnames["$lease_key"]=$lease_hostname
      fi
    done < <(journalctl -b -o cat _COMM=dnsmasq --grep=DHCPACK --no-pager 2>/dev/null)
    local needs_service_lookup=0
    local -A service_macs=()
    local lookup_row lookup_mac lookup_ip
    for lookup_row in "${station_rows[@]}"; do
      IFS=$'\t' read -r lookup_mac lookup_ip <<<"$lookup_row"
      lookup_mac=${lookup_mac,,}
      if [[ -z ${client_hostnames["$lookup_mac"]:-} && -n ${client_ips["$lookup_mac"]:-} ]]; then
        service_macs["${client_ips["$lookup_mac"]}"]=$lookup_mac
        needs_service_lookup=1
      fi
    done
    if ((needs_service_lookup)) && command -v avahi-browse >/dev/null 2>&1; then
      local record browse_iface protocol service_name service_type domain mdns_hostname service_ip port remainder station_mac
      while IFS=';' read -r record browse_iface protocol service_name service_type domain mdns_hostname service_ip port remainder; do
        [[ $record == "=" && $protocol == "IPv4" && $service_type == "_rdlink._tcp" ]] || continue
        station_mac=${service_macs["$service_ip"]:-}
        [[ -n $station_mac && -n $mdns_hostname ]] || continue
        mdns_hostname=${mdns_hostname%.local}
        [[ -n $mdns_hostname ]] && client_hostnames["$station_mac"]=$mdns_hostname
      done < <(avahi-browse --resolve --terminate --parsable _rdlink._tcp 2>/dev/null)
    fi
    if mkdir -p "$cache_dir" 2>/dev/null; then
      local cache_tmp="$cache_file.tmp.$$" cached_mac
      : >"$cache_tmp"
      for cached_mac in "${!client_hostnames[@]}"; do
        printf '%s\t%s\n' "$cached_mac" "${client_hostnames[$cached_mac]}" >>"$cache_tmp"
      done
      mv -f "$cache_tmp" "$cache_file" 2>/dev/null || rm -f "$cache_tmp"
    fi
  fi
  local row row_mac row_signal hostname alias first=1
  for row in "${station_rows[@]}"; do
    IFS=$'\t' read -r row_mac row_signal <<<"$row"
    row_mac=${row_mac,,}
    hostname=${client_hostnames["$row_mac"]:-}
    alias=${client_aliases["$row_mac"]:-}
    [[ $first == 1 ]] || printf '\n'
    first=0
    printf '%s\t%s\t%s\t%s' "$row_mac" "$row_signal" "$hostname" "$alias"
  done
}

status() {
  local capable=0 active=0 configured=0 iface ssid band password freq ip clients upstream max_clients security
  local client_list client_count

  if ap_capable; then capable=1; fi
  if profile_active; then active=1; fi
  if profile_configured; then configured=1; fi

  iface=""
  ssid=""
  band=""
  password=""
  freq=""
  ip=""
  clients="[]"
  client_count=0
  upstream="none"
  max_clients=""

  # Interface, upstream and credentials are profile state, not hardware
  # state: report them even when the (occasionally flaky) `iw phy` AP probe
  # fails, so one bad poll doesn't blank the panel and its client list.
  iface=$(ap_iface)
  upstream=$(upstream_type)
  # The profile is the single source of truth; these ride along so the
  # panel can repopulate its editable fields after a restart.
  ssid=$(profile_ssid)
  band=$(profile_band)
  password=$(profile_secret)
  max_clients=$(profile_max_clients)
  security=$(profile_security)

  if ((active)) && [[ -n $iface ]]; then
    freq=$(iw dev "$iface" link 2>/dev/null | awk '/freq:/ { print $2; exit }')
    ip=$(ip -j addr show dev "$iface" 2>/dev/null |
      jq -r '.[0].addr_info[]? | select(.family == "inet") | .local' 2>/dev/null | head -n 1)
    client_list=$(station_list "$iface")
    if [[ -n $client_list ]]; then
      client_count=$(printf '%s\n' "$client_list" | grep -c . || true)
      clients=$(printf '%s\n' "$client_list" |
        jq -R 'split("\t") as $f | { mac: $f[0], signal: ($f[1] | tonumber? // 0), hostname: ($f[2] // ""), alias: ($f[3] // "") }' 2>/dev/null |
        jq -cs . 2>/dev/null || echo "[]")
    fi
  fi

  printf 'ap_capable\t%d\n' "$capable"
  printf 'active\t%d\n' "$active"
  printf 'configured\t%d\n' "$configured"
  printf 'iface\t%s\n' "$iface"
  printf 'ssid\t%s\n' "$ssid"
  printf 'band\t%s\n' "$band"
  printf 'ap_bands\t%s\n' "$(ap_bands)"
  printf 'password\t%s\n' "$password"
  printf 'max_clients\t%s\n' "$max_clients"
  printf 'security\t%s\n' "$security"
  printf 'freq\t%s\n' "$freq"
  printf 'ip\t%s\n' "$ip"
  printf 'client_count\t%d\n' "$client_count"
  printf 'clients\t%s\n' "$clients"
  printf 'upstream\t%s\n' "$upstream"
}

ipv4_forwarding_enabled() {
  [[ $(sysctl -n net.ipv4.ip_forward 2>/dev/null || true) == 1 ]]
}

ensure_ipv4_forwarding() {
  ipv4_forwarding_enabled && return
  local -a setter=(sysctl -q -w net.ipv4.ip_forward=1)
  if (( EUID == 0 )); then
    "${setter[@]}" >/dev/null
  elif [[ -t 0 ]]; then
    sudo "${setter[@]}" >/dev/null
  else
    pkexec "${setter[@]}" >/dev/null
  fi || fail "could not enable IPv4 forwarding for hotspot internet access"
}

# Password arrives on stdin (never argv). band is optional, default 2.4.
# max is optional: "unlimited"/empty clears the participant limit, else 1-253.
# security is optional: wpa2/wpa3, empty keeps the profile's (wpa2 when new).
# apply() writes the profile; start() writes it the same way, then brings the AP up.
start() {
  local ssid=$1 band=${2:-2.4} max=${3:-} security=${4:-}

  ensure_ipv4_forwarding
  apply "$ssid" "$band" "$max" "$security"

  if ! nmcli connection up "$PROFILE" >/dev/null 2>&1; then
    fail "could not start hotspot (does this adapter allow AP mode?)"
  fi
}

stop() {
  if profile_active; then
    nmcli connection down "$PROFILE" >/dev/null 2>&1 || true
  fi
}

# The menu entry: flip the current state. When nothing has been configured
# yet, hand over to the network panel instead of inventing credentials.
toggle() {
  if profile_active; then
    stop
  elif profile_configured; then
    local ssid band password
    ssid=$(profile_ssid)
    band=$(profile_band)
    password=$(profile_secret)
    [[ -n $ssid ]] || fail "no hotspot SSID configured"
    [[ -n $password ]] || fail "no saved hotspot password"
    printf '%s\n' "$password" | start "$ssid" "$band" "$(profile_max_clients)"
  else
    omarchy-shell shell summon ujo4eva.network '{"focus":"hotspot"}' 2>/dev/null || true
  fi
}

qr() {
  local ssid password iface security payload ascii
  iface=$(ap_iface)
  ssid=$(profile_ssid)
  password=$(profile_secret)
  [[ -n $ssid ]] || fail "no hotspot configured"
  [[ -n $password ]] || fail "no hotspot password"

  escape() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//;/\\;}
    value=${value//,/\\,}
    value=${value//:/\\:}
    printf '%s' "$value"
  }

  security=WPA
  payload="WIFI:T:$security;S:$(escape "$ssid");P:$(escape "$password");;"

  printf 'meta\t%s\t%s\t%s\n' "$iface" "$security" "$ssid"
  ascii=$(printf '%s' "$payload" | qrencode --type ASCII --margin 4 --output -)
  while IFS= read -r line; do
    row=
    for ((column = 0; column < ${#line}; column += 2)); do
      [[ ${line:column:2} == *#* ]] && row+=1 || row+=0
    done
    printf '%s\n' "$row"
  done <<<"$ascii"
}

# Persist credentials to the NetworkManager profile without starting the AP.
# Password arrives on stdin (never argv). Edits survive shell restarts even
# when the user never turns the hotspot on. `apply` is idempotent: it creates
# the profile on first use, then updates it. start() reuses this path.
# The participant limit is enforced as a shared-DHCP range handing out exactly
# N leases (devices past the Nth associate but get no address). A changed
# limit bounces a live AP so dnsmasq picks it up now; SSID/password edits
# still wait for the next manual start.
apply() {
  local ssid=$1 band=${2:-2.4} max=${3:-} security=${4:-} password device nm_band nm_channel
  local old_range old_band old_security new_range="" base="" bounce=0
  local -a security_args

  ap_capable || fail "no Wi-Fi adapter supports AP mode"
  device=$(first_wifi_device)
  [[ -n $device ]] || fail "no Wi-Fi device found"

  IFS= read -r password || true
  [[ -n $ssid ]] || fail "SSID required"
  [[ ${#password} -ge 8 && ${#password} -le 63 ]] ||
    fail "password must be 8-63 characters"
  nm_band=$(nm_band_for "$band") || fail "unknown band '$band' (use 2.4, 5 or 6)"
  nm_channel=$(nm_channel_for "$band")
  old_range=$(nm_get ipv4.shared-dhcp-range connection show "$PROFILE")
  old_band=$(profile_band)
  old_security=$(profile_security)
  [[ -n $security ]] || security=$old_security
  read -ra security_args <<<"$(nm_security_args "$security")"
  ((${#security_args[@]})) || fail "unknown security '$security' (use wpa2 or wpa3)"
  if [[ -n $max && $max != "unlimited" ]]; then
    new_range=$(dhcp_range_for "$max")
    base=$(shared_base)
  fi

  if profile_configured; then
    # SSID/band ride argv (not secret); the passphrase goes through the
    # scriptable editor so it never shows up in /proc.
    # Band, channel and width change together: NM rejects a band whose saved
    # channel or width belongs to another band (2.4 GHz with channel 149 or an
    # 80 MHz width), so the width goes back to auto for the new band.
    nmcli connection modify "$PROFILE" ssid "$ssid" 802-11-wireless.band "$nm_band" \
      802-11-wireless.channel "$nm_channel" 802-11-wireless.channel-width auto \
      "${security_args[@]}" >/dev/null 2>&1 ||
      fail "could not apply hotspot settings"
    printf 'set wifi-sec.psk %s\nsave\nquit\n' "$password" |
      nmcli connection edit "$PROFILE" >/dev/null 2>&1 ||
      fail "could not apply hotspot password"
  else
    nmcli connection add type wifi ifname "$device" con-name "$PROFILE" ssid "$ssid" \
      mode ap 802-11-wireless.band "$nm_band" 802-11-wireless.channel "$nm_channel" \
      "${security_args[@]}" ipv4.method shared autoconnect no >/dev/null ||
      fail "could not create hotspot profile"
    printf 'set wifi-sec.psk %s\nsave\nquit\n' "$password" |
      nmcli connection edit "$PROFILE" >/dev/null 2>&1 ||
      fail "could not set hotspot password"
  fi

  if [[ $new_range != "$old_range" ]]; then
    if [[ -n $new_range ]]; then
      # The range must sit inside a configured network: pin NM's default
      # shared subnet when the profile has none yet, otherwise keep whatever
      # subnet is already there.
      if [[ -z $(nm_get ipv4.addresses connection show "$PROFILE") ]]; then
        nmcli connection modify "$PROFILE" ipv4.addresses "$base.1/24" >/dev/null 2>&1 ||
          fail "could not set hotspot subnet"
      fi
      nmcli connection modify "$PROFILE" ipv4.shared-dhcp-range "$new_range" >/dev/null 2>&1 ||
        fail "could not apply participant limit"
    else
      nmcli connection modify "$PROFILE" ipv4.shared-dhcp-range "" >/dev/null 2>&1 ||
        fail "could not clear participant limit"
    fi
    bounce=1
  fi
  # A band or security change is as live as a limit change: the AP keeps the
  # old channel and key management until it is bounced. SSID/password still
  # wait for the next manual start.
  if [[ $band != "$old_band" || $security != "$old_security" ]]; then
    bounce=1
  fi
  if ((bounce)) && profile_active; then
    nmcli connection down "$PROFILE" >/dev/null 2>&1 || true
    nmcli connection up "$PROFILE" >/dev/null 2>&1 ||
      fail "settings saved but the hotspot could not be restarted"
  fi
}

usage() {
  echo "Usage: hotspot.sh <status|start|stop|toggle|qr|apply|alias-set|alias-remove|generate-password> [args...]" >&2
}

case "${1:-}" in
  status) status ;;
  start) shift; start "$@" ;;
  stop) stop ;;
  toggle) toggle ;;
  qr) qr ;;
  apply) shift; apply "$@" ;;
  alias-set) shift; set_participant_alias "$@" ;;
  alias-remove) shift; remove_participant_alias "$@" ;;
  generate-password) generate_password ;;
  *) usage; exit 2 ;;
esac
