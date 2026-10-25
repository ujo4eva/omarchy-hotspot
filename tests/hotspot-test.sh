#!/bin/bash
set -euo pipefail

PLUGIN=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plugin/ujo4eva.network/hotspot.sh}
STATE_DIR=$(mktemp -d)
trap 'rm -rf "$STATE_DIR"' EXIT
printf '0\n' >"$STATE_DIR/ip-forward"
mkdir -p "$STATE_DIR/runtime"
export STATE_DIR

# The mocks reach the plugin through `export -f` below.
# shellcheck disable=SC2329
iw() {
  case ${1:-} in
    phy)
      printf '%s\n' \
        'Wiphy phy0' \
        '        Supported interface modes:' \
        '                 * AP' \
        '        Band 1:' \
        '                Frequencies:' \
        '                        * 2412.0 MHz [1] (22.0 dBm)' \
        '                        * 2437.0 MHz [6] (22.0 dBm)' \
        '        Band 2:' \
        '                Frequencies:' \
        '                        * 5180.0 MHz [36] (22.0 dBm) (no IR)' \
        '                        * 5745.0 MHz [149] (22.0 dBm)'
      ;;
    dev)
      if [[ ${3:-} == station ]]; then
        printf '%s\n' \
          'Station aa:bb:cc:dd:ee:ff' \
          '    signal: -55 dBm' \
          '    signal avg: -55 dBm' \
          'Station 11:22:33:44:55:66' \
          '    signal: -45 dBm' \
          '    signal avg: -45 dBm'
      elif [[ ${3:-} == link ]]; then
        printf '%s\n' '    freq: 2437'
      fi
      ;;
  esac
}

nmcli() {
  printf '%s\n' "$*" >>"$STATE_DIR/nmcli-calls"
  case " $* " in
    *" -g 802-11-wireless-security.key-mgmt connection show "*)
      cat "$STATE_DIR/key-mgmt" 2>/dev/null || true
      ;;
    *" -g 802-11-wireless-security.pmf connection show "*)
      cat "$STATE_DIR/pmf" 2>/dev/null || true
      ;;
    *" -g NAME connection show "*)
      printf '%s\n' ujo4eva-hotspot
      ;;
    *" -g GENERAL.DEVICE connection show "*)
      printf '%s\n' wlo1
      ;;
    *" -t -f NAME connection show --active "*)
      printf '%s\n' ujo4eva-hotspot
      ;;
    *" -f DEVICE,TYPE device status "*)
      printf '%s\n' wlo1:wifi
      ;;
    *" connection edit "*)
      while IFS= read -r _; do :; done
      ;;
  esac
}

journalctl() {
  printf 'x' >>"$STATE_DIR/journal-calls"
  printf '%s\n' \
    '1758144000 DHCPACK(wlo1) 10.42.0.42 aa:bb:cc:dd:ee:ff Redmi-Note-13' \
    '1758144000 DHCPACK(wlo1) 10.42.0.86 11:22:33:44:55:66 *'
}

avahi-browse() {
  printf 'a' >>"$STATE_DIR/avahi-calls"
  printf '%s\n' '=;wlo1;IPv4;Gabriel\226\128\153s\032X;_rdlink._tcp;local;Gabriels-X.local;10.42.0.86;49158'
}

ip() {
  if [[ ${1:-} == -j ]]; then
    printf '%s\n' '[{"addr_info":[{"family":"inet","local":"10.42.0.1"}]}]'
  else
    command /usr/bin/ip "$@"
  fi
}

sysctl() {
  local argument
  for argument in "$@"; do
    case $argument in
      net.ipv4.ip_forward)
        IFS= read -r value <"$STATE_DIR/ip-forward"
        printf '%s\n' "$value"
        return
        ;;
      net.ipv4.ip_forward=1)
        printf '1\n' >"$STATE_DIR/ip-forward"
        return
        ;;
    esac
  done
  return 1
}

pkexec() {
  local command=$1
  shift
  "$command" "$@"
}

sudo() {
  pkexec "$@"
}

export -f iw nmcli ip journalctl avahi-browse sysctl pkexec sudo

printf '%s\n' test-password |
  MOCK_STATE_DIR="$STATE_DIR" bash "$PLUGIN" start TestHotspot 2.4 unlimited

IFS= read -r forwarding <"$STATE_DIR/ip-forward"
if [[ $forwarding != 1 ]]; then
  printf 'FAIL: hotspot start left IPv4 forwarding disabled\n' >&2
  exit 1
fi
printf 'PASS: hotspot start enables IPv4 forwarding\n'

# Every mode pins RSN/CCMP: unpinned, the AP picks a TKIP group cipher that
# Android's auto-upgraded WPA3 profile rejects, and an SAE-only AP will not
# start. A profile with no saved security gets the mixed WPA2/WPA3 default.
if ! grep -q 'connection modify .*wifi-sec.key-mgmt wpa-psk wifi-sec.pmf optional wifi-sec.proto rsn wifi-sec.pairwise ccmp wifi-sec.group ccmp' "$STATE_DIR/nmcli-calls"; then
  printf 'FAIL: hotspot start did not default to mixed WPA2/WPA3 with CCMP pinned\n' >&2
  exit 1
fi
printf 'wpa-psk\n' >"$STATE_DIR/key-mgmt"
printf '1\n' >"$STATE_DIR/pmf"
if ! XDG_RUNTIME_DIR="$STATE_DIR/runtime" bash "$PLUGIN" status | grep -qx $'security\twpa2'; then
  printf 'FAIL: hotspot status did not report WPA2 for PSK with PMF disabled\n' >&2
  exit 1
fi
printf '0\n' >"$STATE_DIR/pmf"
if ! XDG_RUNTIME_DIR="$STATE_DIR/runtime" bash "$PLUGIN" status | grep -qx $'security\tmixed'; then
  printf 'FAIL: hotspot status did not report mixed for PSK with PMF allowed\n' >&2
  exit 1
fi
rm -f "$STATE_DIR/pmf"
printf 'sae\n' >"$STATE_DIR/key-mgmt"
: >"$STATE_DIR/nmcli-calls"
printf '%s\n' test-password | bash "$PLUGIN" apply TestHotspot 2.4 unlimited
if ! grep -q 'connection modify .*wifi-sec.key-mgmt sae wifi-sec.pmf required wifi-sec.proto rsn wifi-sec.pairwise ccmp wifi-sec.group ccmp' "$STATE_DIR/nmcli-calls"; then
  printf 'FAIL: hotspot apply without a security argument dropped the saved WPA3\n' >&2
  exit 1
fi
if ! XDG_RUNTIME_DIR="$STATE_DIR/runtime" bash "$PLUGIN" status | grep -qx $'security\twpa3'; then
  printf 'FAIL: hotspot status did not report WPA3 for an SAE profile\n' >&2
  exit 1
fi
: >"$STATE_DIR/nmcli-calls"
printf '%s\n' test-password | bash "$PLUGIN" apply TestHotspot 2.4 unlimited wpa2
if ! grep -q 'connection modify .*wifi-sec.key-mgmt wpa-psk wifi-sec.pmf disable wifi-sec.proto rsn wifi-sec.pairwise ccmp wifi-sec.group ccmp' "$STATE_DIR/nmcli-calls"; then
  printf 'FAIL: hotspot apply wpa2 did not switch the profile back to PSK\n' >&2
  exit 1
fi
if ! grep -qx 'connection up ujo4eva-hotspot' "$STATE_DIR/nmcli-calls"; then
  printf 'FAIL: a security change did not bounce the live hotspot\n' >&2
  exit 1
fi
rm -f "$STATE_DIR/key-mgmt"
if printf '%s\n' test-password | bash "$PLUGIN" apply TestHotspot 2.4 unlimited wep >/dev/null 2>&1; then
  printf 'FAIL: hotspot accepted an unknown security mode\n' >&2
  exit 1
fi
node -e '
const fs = require("fs")
const vm = require("vm")
vm.runInThisContext(fs.readFileSync(process.argv[1], "utf8"))
if (hotspotSecurity({ security: "wpa3" }) !== "wpa3" || hotspotSecurity({ security: "wpa2" }) !== "wpa2" ||
    hotspotSecurity({ security: "" }) !== "mixed" || hotspotSecurity({}) !== "mixed") {
  process.stderr.write("FAIL: hotspotSecurity did not normalize to wpa2/mixed/wpa3\n")
  process.exit(1)
}
' "${PLUGIN%/*}/Model.js"
printf 'PASS: hotspot security defaults to mixed, reads and keeps the saved mode, and switches live\n'

status_output=$(XDG_RUNTIME_DIR="$STATE_DIR/runtime" bash "$PLUGIN" status)
node -e '
const fs = require("fs")
const vm = require("vm")
vm.runInThisContext(fs.readFileSync(process.argv[1], "utf8"))
const status = parseHotspotStatus(fs.readFileSync(0, "utf8"))
const clients = hotspotClients(status)
if (clients.length !== 2) {
  process.stderr.write("FAIL: hotspot status lost a connected client\n")
  process.exit(1)
}
const names = Object.fromEntries(clients.map(client => [client.mac, client.hostname]))
if (names["aa:bb:cc:dd:ee:ff"] !== "Redmi-Note-13") {
  process.stderr.write("FAIL: hotspot status lost the DHCP hostname\n")
  process.exit(1)
}
if (names["11:22:33:44:55:66"] !== "Gabriels-X") {
  process.stderr.write("FAIL: hotspot status lost the Bonjour hostname\n")
  process.exit(1)
}
' "${PLUGIN%/*}/Model.js" <<<"$status_output"

XDG_RUNTIME_DIR="$STATE_DIR/runtime" bash "$PLUGIN" status >/dev/null
journal_calls=$(<"$STATE_DIR/journal-calls")
avahi_calls=$(<"$STATE_DIR/avahi-calls")
if [[ $journal_calls != x || $avahi_calls != a ]]; then
  printf 'FAIL: hotspot status did not cache discovered hostnames\n' >&2
  exit 1
fi
printf 'PASS: hotspot status preserves connected clients and hostnames\n'

printf '%s\n' 'Work iPhone' |
  XDG_CONFIG_HOME="$STATE_DIR/config" bash "$PLUGIN" alias-set 11:22:33:44:55:66
alias_status=$(XDG_CONFIG_HOME="$STATE_DIR/config" XDG_RUNTIME_DIR="$STATE_DIR/runtime" bash "$PLUGIN" status)
node -e '
const fs = require("fs")
const vm = require("vm")
vm.runInThisContext(fs.readFileSync(process.argv[1], "utf8"))
const status = parseHotspotStatus(fs.readFileSync(0, "utf8"))
const client = hotspotClients(status).find(client => client.mac === "11:22:33:44:55:66")
if (!client || client.alias !== "Work iPhone") {
  process.stderr.write("FAIL: hotspot status lost the manual participant alias\n")
  process.exit(1)
}
if (!hotspotClientLabel(client).startsWith("Work iPhone")) {
  process.stderr.write("FAIL: participant label did not prefer the manual alias\n")
  process.exit(1)
}
' "${PLUGIN%/*}/Model.js" <<<"$alias_status"
alias_file="$STATE_DIR/config/omarchy/ujo4eva.network/participant-aliases.tsv"
if [[ $(stat -c '%a' "$alias_file") != 600 ]]; then
  printf 'FAIL: participant alias file is not private\n' >&2
  exit 1
fi
if printf 'bad\talias\n' |
  XDG_CONFIG_HOME="$STATE_DIR/config" bash "$PLUGIN" alias-set 11:22:33:44:55:66 >/dev/null 2>&1; then
  printf 'FAIL: hotspot accepted a control character in an alias\n' >&2
  exit 1
fi
if printf '%065d\n' 0 |
  XDG_CONFIG_HOME="$STATE_DIR/config" bash "$PLUGIN" alias-set 11:22:33:44:55:66 >/dev/null 2>&1; then
  printf 'FAIL: hotspot accepted an overlong alias\n' >&2
  exit 1
fi
XDG_CONFIG_HOME="$STATE_DIR/config" bash "$PLUGIN" alias-remove 11:22:33:44:55:66
alias_status=$(XDG_CONFIG_HOME="$STATE_DIR/config" XDG_RUNTIME_DIR="$STATE_DIR/runtime" bash "$PLUGIN" status)
node -e '
const fs = require("fs")
const vm = require("vm")
vm.runInThisContext(fs.readFileSync(process.argv[1], "utf8"))
const status = parseHotspotStatus(fs.readFileSync(0, "utf8"))
const client = hotspotClients(status).find(client => client.mac === "11:22:33:44:55:66")
if (!client || client.alias !== "" || client.hostname !== "Gabriels-X") {
  process.stderr.write("FAIL: removing an alias did not restore the discovered hostname\n")
  process.exit(1)
}
' "${PLUGIN%/*}/Model.js" <<<"$alias_status"
printf 'PASS: participant aliases persist, validate, and restore discovery\n'

if ! grep -qx $'ap_bands\t2.4,5' <<<"$status_output"; then
  printf 'FAIL: hotspot status did not report usable AP bands\n' >&2
  printf '%s\n' "$status_output" >&2
  exit 1
fi
node -e '
const fs = require("fs")
const vm = require("vm")
vm.runInThisContext(fs.readFileSync(process.argv[1], "utf8"))
const both = hotspotBands({ ap_bands: "2.4,5" })
if (both.join(",") !== "2.4,5") {
  process.stderr.write("FAIL: hotspotBands did not keep 2.4 and 5\n")
  process.exit(1)
}
if (hotspotDefaultBand({ ap_bands: "2.4,5", band: "5" }) !== "5") {
  process.stderr.write("FAIL: hotspotDefaultBand did not keep the saved 5 GHz profile\n")
  process.exit(1)
}
if (hotspotDefaultBand({ ap_bands: "2.4,5", band: "6" }) !== "2.4") {
  process.stderr.write("FAIL: hotspotDefaultBand did not fall back from an unsupported band\n")
  process.exit(1)
}
if (hotspotBands({}).join(",") !== "2.4,5") {
  process.stderr.write("FAIL: hotspotBands should offer 2.4 and 5 when status is empty\n")
  process.exit(1)
}
' "${PLUGIN%/*}/Model.js"
printf 'PASS: hotspot status reports AP bands and Model.js picks 2.4/5\n'

# Regression: with pipefail, `iw phy | grep -q` fails when grep exits on the
# first match and iw is still writing. Emit the AP line early, then far more
# than a pipe buffer, so the old pipeline loses the race every time.
iw() {
  if [[ ${1:-} == phy ]]; then
    printf '%s\n' 'Wiphy phy0' '        Supported interface modes:' '                 * AP'
    local i
    for ((i = 0; i < 20000; i++)); do
      echo '                        * 2412.0 MHz [1] (22.0 dBm) padding padding'
    done
    return 0
  fi
  return 0
}
export -f iw
capable=$(XDG_RUNTIME_DIR="$STATE_DIR/runtime" bash "$PLUGIN" status 2>/dev/null |
  awk -F'\t' '$1 == "ap_capable" { print $2 }')
if [[ $capable != 1 ]]; then
  printf 'FAIL: ap_capable missed AP mode in long iw phy output (got %s)\n' "${capable:-nothing}" >&2
  exit 1
fi
printf 'PASS: ap_capable survives iw phy output larger than a pipe buffer\n'
