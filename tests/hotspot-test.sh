#!/bin/bash
set -euo pipefail

PLUGIN=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plugin/ujo4eva.network/hotspot.sh}
STATE_DIR=$(mktemp -d)
trap 'rm -rf "$STATE_DIR"' EXIT
printf '0\n' >"$STATE_DIR/ip-forward"
mkdir -p "$STATE_DIR/runtime"
# The plugin keeps its forwarding marker and hostname cache in the runtime
# directory; keep the test's out of the real one.
export STATE_DIR XDG_RUNTIME_DIR="$STATE_DIR/runtime"

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
    *" -g NAME connection show --active "*)
      [[ -e $STATE_DIR/ap-down ]] || printf '%s\n' ujo4eva-hotspot
      [[ -z ${MOCK_OTHER_SHARED:-} ]] || printf '%s\n' "$MOCK_OTHER_SHARED"
      ;;
    *" -g NAME connection show "*)
      # MOCK_NO_PROFILE stands in for a machine that has never saved a hotspot.
      [[ -n ${MOCK_NO_PROFILE:-} ]] || printf '%s\n' ujo4eva-hotspot
      ;;
    *" -g ipv4.addresses connection show "*)
      cat "$STATE_DIR/addresses" 2>/dev/null || true
      ;;
    *" -g GENERAL.DEVICE connection show "*)
      printf '%s\n' wlo1
      ;;
    *" -t -f NAME connection show --active "*)
      [[ -e $STATE_DIR/ap-down ]] || printf '%s\n' ujo4eva-hotspot
      ;;
    *" -g ipv4.method connection show "*)
      [[ -z ${MOCK_OTHER_SHARED:-} || " $* " != *" $MOCK_OTHER_SHARED "* ]] || printf '%s\n' shared
      ;;
    *" connection down "*)
      touch "$STATE_DIR/ap-down"
      ;;
    *" connection up "*)
      [[ -z ${MOCK_UP_FAILS:-} ]] || return 1
      rm -f "$STATE_DIR/ap-down"
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
  elif [[ $* == "-o link show" ]]; then
    printf '%s\n' '1: lo: <LOOPBACK,UP> mtu 65536' '2: wlo1: <BROADCAST,UP> mtu 1500'
    [[ -z ${MOCK_LINK:-} ]] || printf '3: %s@if4: <BROADCAST,UP> mtu 1500\n' "$MOCK_LINK"
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
      net.ipv4.ip_forward=0)
        printf '0\n' >"$STATE_DIR/ip-forward"
        return
        ;;
    esac
  done
  return 1
}

# Both run the command; each notes its name so a test can tell which prompt
# the plugin chose.
pkexec() {
  local command=$1
  shift
  printf 'pkexec\n' >>"$STATE_DIR/prompts"
  "$command" "$@"
}

sudo() {
  local command=$1
  shift
  printf 'sudo\n' >>"$STATE_DIR/prompts"
  "$command" "$@"
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
node -e '
const fs = require("fs")
const vm = require("vm")
vm.runInThisContext(fs.readFileSync(process.argv[1], "utf8"))
// 60px at 30px/s scrolls for 2s, with 1.5s rests: rest, scroll out, rest, scroll back.
const at = ms => marqueeOffset(ms, 60, 1500, 30)
if (at(0) !== 0 || at(1499) !== 0 || at(3500) !== -60 || at(4999) !== -60 || at(7000) !== 0 || at(7000 + 3500) !== -60 ||
    !(at(2500) < 0 && at(2500) > -60) || marqueeOffset(5000, 0, 1500, 30) !== 0) {
  process.stderr.write("FAIL: marqueeOffset did not rest, scroll and return on its period\n")
  process.exit(1)
}
' "${PLUGIN%/*}/Model.js"
printf 'PASS: long participant labels scroll on one shared clock\n'

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

# shared mode needs an address on the AP interface: without one NetworkManager
# brings the radio up and then fails "IP configuration could not be reserved".
: >"$STATE_DIR/nmcli-calls"
printf '%s\n' test-password | MOCK_NO_PROFILE=1 bash "$PLUGIN" apply TestHotspot 2.4 unlimited
if ! grep -q 'connection add .*ipv4.method shared ipv4.addresses 10.42.0.1/24' "$STATE_DIR/nmcli-calls"; then
  printf 'FAIL: a new hotspot profile has no shared IPv4 address\n' >&2
  exit 1
fi
printf 'PASS: a new hotspot profile gets the shared IPv4 address\n'

# Without dnsmasq, shared mode can't hand out leases; start has to say so
# instead of blaming the adapter. PATH keeps every binary except dnsmasq.
no_dnsmasq="$STATE_DIR/no-dnsmasq-bin"
mkdir -p "$no_dnsmasq"
for binary in /usr/bin/*; do
  [[ ${binary##*/} == "dnsmasq" ]] || ln -s "$binary" "$no_dnsmasq/${binary##*/}"
done
if output=$(printf '%s\n' test-password | PATH="$no_dnsmasq" MOCK_STATE_DIR="$STATE_DIR" bash "$PLUGIN" start TestHotspot 2.4 unlimited 2>&1); then
  printf 'FAIL: hotspot start succeeded without dnsmasq\n' >&2
  exit 1
fi
if [[ $output != *"dnsmasq is required"* ]]; then
  printf 'FAIL: hotspot start without dnsmasq did not name it: %s\n' "$output" >&2
  exit 1
fi
printf 'PASS: hotspot start without dnsmasq names the missing package\n'

# A password piped in from a terminal still prompts there: sudo, not pkexec.
printf '0\n' >"$STATE_DIR/ip-forward"
: >"$STATE_DIR/prompts"
script -qec "bash -c 'printf \"%s\\n\" test-password | bash \"$PLUGIN\" start TestHotspot 2.4 unlimited'" /dev/null >/dev/null </dev/null
if [[ $(<"$STATE_DIR/prompts") != sudo ]]; then
  printf 'FAIL: a terminal with piped stdin did not prompt with sudo: %s\n' "$(<"$STATE_DIR/prompts")" >&2
  exit 1
fi
printf '0\n' >"$STATE_DIR/ip-forward"
: >"$STATE_DIR/prompts"
# stdin is the password pipe and stderr goes to a file: no terminal anywhere.
printf '%s\n' test-password | bash "$PLUGIN" start TestHotspot 2.4 unlimited 2>"$STATE_DIR/no-terminal.err"
if [[ $(<"$STATE_DIR/prompts") != pkexec ]]; then
  printf 'FAIL: no terminal did not prompt with pkexec: %s\n' "$(<"$STATE_DIR/prompts")" >&2
  exit 1
fi
printf 'PASS: the forwarding prompt is sudo whenever a terminal is attached\n'

# A custom profile address never ends up inside its own lease range.
printf '%s\n' 10.42.0.2/24 >"$STATE_DIR/addresses"
: >"$STATE_DIR/nmcli-calls"
printf '%s\n' test-password | bash "$PLUGIN" apply TestHotspot 2.4 1
if ! grep -q 'ipv4.shared-dhcp-range 10.42.0.3,10.42.0.3' "$STATE_DIR/nmcli-calls"; then
  printf 'FAIL: the lease range did not step past a .2 gateway: %s\n' "$(grep shared-dhcp-range "$STATE_DIR/nmcli-calls")" >&2
  exit 1
fi
printf '%s\n' 10.42.0.254/24 >"$STATE_DIR/addresses"
: >"$STATE_DIR/nmcli-calls"
printf '%s\n' test-password | bash "$PLUGIN" apply TestHotspot 2.4 4
if ! grep -q 'ipv4.shared-dhcp-range 10.42.0.250,10.42.0.253' "$STATE_DIR/nmcli-calls"; then
  printf 'FAIL: the lease range did not sit below a .254 gateway\n' >&2
  exit 1
fi
rm -f "$STATE_DIR/addresses"
printf 'PASS: the lease range never includes the hotspot address\n'

# Overlapping alias saves take turns, so none of them is lost.
for i in $(seq 10 29); do
  printf 'Device %s\n' "$i" | XDG_CONFIG_HOME="$STATE_DIR/concurrent" bash "$PLUGIN" alias-set "aa:bb:cc:dd:ee:$i" &
done
wait
concurrent_file="$STATE_DIR/concurrent/omarchy/ujo4eva.network/participant-aliases.tsv"
if [[ $(wc -l <"$concurrent_file") != 20 ]]; then
  printf 'FAIL: overlapping alias saves lost names: %s of 20\n' "$(wc -l <"$concurrent_file")" >&2
  exit 1
fi
printf 'PASS: overlapping alias saves keep every name\n'

# An alias file that can't be read is left alone rather than rewritten.
if (( EUID != 0 )); then
  cp "$concurrent_file" "$STATE_DIR/aliases-before"
  chmod 000 "$concurrent_file"
  if printf 'New Name\n' | XDG_CONFIG_HOME="$STATE_DIR/concurrent" bash "$PLUGIN" alias-set aa:bb:cc:dd:ee:07 >/dev/null 2>&1; then
    chmod 600 "$concurrent_file"
    printf 'FAIL: saving into an unreadable alias file succeeded\n' >&2
    exit 1
  fi
  chmod 600 "$concurrent_file"
  if ! cmp -s "$concurrent_file" "$STATE_DIR/aliases-before"; then
    printf 'FAIL: an unreadable alias file lost names\n' >&2
    exit 1
  fi
  if compgen -G "$concurrent_file.??????" >/dev/null; then
    printf 'FAIL: a refused alias save left a temp file behind\n' >&2
    exit 1
  fi
fi
printf 'PASS: an unreadable alias file is never rewritten\n'

# The panel's first status after opening fills only fields the user hasn't
# changed yet. Runs the panel's own updateHotspot against Model.js.
node -e '
const fs = require("fs")
const vm = require("vm")
const dir = process.argv[1]
const Model = {}
vm.runInNewContext(fs.readFileSync(dir + "/Model.js", "utf8") + "\nfor (const k of Object.keys(this)) Model[k] = this[k]", { Model })
const panel = fs.readFileSync(dir + "/Panel.qml", "utf8")
const source = panel.match(/function updateHotspot\(raw\) \{[\s\S]*?\n  \}/)
if (!source) { process.stderr.write("FAIL: the panel has no updateHotspot\n"); process.exit(1) }
const state = {
  hotspot: {}, hotspotLoaded: false, hotspotEditedFields: { ssid: true }, hotspotSsid: "Typed Name", hotspotPassword: "stalepassword",
  hotspotSavedSsid: "", hotspotSavedPassword: "", hotspotMaxClients: "", hotspotBand: "5", hotspotSecurity: "wpa3",
  hotspotAvailableBands: [], Model, syncWifiNetworks() {}, refreshWifiList() {},
}
const run = raw => new Function("state", "raw", "with (state) {\n" + source[0] + "\nupdateHotspot(raw)\n}")(state, raw)
const saved = "ap_capable\t1\nactive\t0\nconfigured\t1\niface\twlo1\nssid\tSaved Name\nband\t2.4\nap_bands\t2.4,5\npassword\tsavedpassword\nmax_clients\t4\nsecurity\tmixed\n"
run(saved)
if (state.hotspotSsid !== "Typed Name") {
  process.stderr.write("FAIL: a late first status replaced the field the user had edited\n"); process.exit(1)
}
if (state.hotspotPassword !== "savedpassword" || state.hotspotBand !== "2.4" || state.hotspotSecurity !== "mixed" || state.hotspotMaxClients !== "4") {
  process.stderr.write("FAIL: an edit to one field stopped the others from loading\n"); process.exit(1)
}
if (state.hotspotSavedSsid !== "Saved Name") { process.stderr.write("FAIL: the saved name did not follow the profile\n"); process.exit(1) }
Object.assign(state, { hotspotLoaded: false, hotspotEditedFields: {} })
run(saved)
if (state.hotspotSsid !== "Saved Name" || state.hotspotMaxClients !== "4" || state.hotspotSecurity !== "mixed") {
  process.stderr.write("FAIL: an untouched panel was not filled from the profile\n"); process.exit(1)
}
' "${PLUGIN%/*}"
printf 'PASS: a late first status keeps the fields the user edited and loads the rest\n'

# Forwarding the plugin turned on goes back off with the AP, unless something
# else still routes; forwarding that was already on stays on.
forwarding_marker="$XDG_RUNTIME_DIR/ujo4eva-hotspot-forwarding"
start_then_stop() {
  printf '0\n' >"$STATE_DIR/ip-forward"
  rm -f "$STATE_DIR/ap-down" "$forwarding_marker"
  printf '%s\n' test-password | bash "$PLUGIN" start TestHotspot 2.4 unlimited 2>/dev/null
  [[ -e $forwarding_marker ]] || { printf 'FAIL: start did not mark forwarding as its own\n' >&2; exit 1; }
  bash "$PLUGIN" stop 2>"$STATE_DIR/stop.err"
}
start_then_stop
if [[ $(<"$STATE_DIR/ip-forward") != 0 || -e $forwarding_marker ]]; then
  printf 'FAIL: stop left the forwarding the hotspot turned on\n' >&2
  exit 1
fi
MOCK_LINK=docker0 start_then_stop
if [[ $(<"$STATE_DIR/ip-forward") != 1 ]] || ! grep -q 'still routing for interface docker0' "$STATE_DIR/stop.err"; then
  printf 'FAIL: stop turned forwarding off under a container bridge\n' >&2
  exit 1
fi
MOCK_OTHER_SHARED=Tether start_then_stop
if [[ $(<"$STATE_DIR/ip-forward") != 1 ]]; then
  printf 'FAIL: stop turned forwarding off under another shared connection\n' >&2
  exit 1
fi
printf '1\n' >"$STATE_DIR/ip-forward"
rm -f "$STATE_DIR/ap-down" "$forwarding_marker"
printf '%s\n' test-password | bash "$PLUGIN" start TestHotspot 2.4 unlimited
bash "$PLUGIN" stop
if [[ $(<"$STATE_DIR/ip-forward") != 1 || -e $forwarding_marker ]]; then
  printf 'FAIL: stop turned off forwarding the hotspot did not turn on\n' >&2
  exit 1
fi
printf '0\n' >"$STATE_DIR/ip-forward"
rm -f "$STATE_DIR/ap-down" "$forwarding_marker"
if printf '%s\n' test-password | MOCK_UP_FAILS=1 bash "$PLUGIN" start TestHotspot 2.4 unlimited 2>/dev/null; then
  printf 'FAIL: a failed AP start reported success\n' >&2
  exit 1
fi
if [[ $(<"$STATE_DIR/ip-forward") != 0 || -e $forwarding_marker ]]; then
  printf 'FAIL: a failed start left forwarding on\n' >&2
  exit 1
fi
rm -f "$STATE_DIR/ap-down"
printf 'PASS: forwarding the hotspot turned on goes back off with it\n'
