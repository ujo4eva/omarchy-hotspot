# Shared paths and helpers for install.sh and uninstall.sh.

PLUGIN_ID="ujo4eva.network"
PROFILE="ujo4eva-hotspot"
OMARCHY_CONFIG="$HOME/.config/omarchy"
PLUGIN_DIR="$OMARCHY_CONFIG/plugins/$PLUGIN_ID"
MENU_FILE="$OMARCHY_CONFIG/extensions/omarchy-menu.jsonc"
SHELL_JSON="$OMARCHY_CONFIG/shell.json"
BACKUP_ROOT="$OMARCHY_CONFIG/backups/omarchy-hotspot"
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
