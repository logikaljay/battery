#!/usr/bin/env bash
# Install (or uninstall) the battery CLI and its Omarchy bar widget.
#
#   curl -fsSL https://raw.githubusercontent.com/logikaljay/battery/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/logikaljay/battery/main/install.sh | bash -s -- --limit 80
#
# Works the same from a checkout: ./install.sh [options]
#
#   --limit <pct>   also set a charge limit and keep it at boot
#   --cli-only      install just the CLI, not the Omarchy widget
#   --no-restart    don't restart the Omarchy shell afterwards
#   --uninstall     remove both and restore Omarchy's Power widget
#
# Environment: PREFIX (default ~/.local) for the CLI, BATTERY_REF (default main)
# for the branch or tag to download.

set -euo pipefail

# Everything runs from main(), called on the last line: piped from curl, bash
# reads the script from stdin as it goes, so nothing runs until all of it is in.
main() {

REPO="logikaljay/battery"
REF=${BATTERY_REF:-main}
PREFIX=${PREFIX:-$HOME/.local}
BIN="$PREFIX/bin/battery"
WIDGET_ID="battery.power"
SOURCE_ID="omarchy.power"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
WIDGET_DIR="$PLUGINS_DIR/$WIDGET_ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
RULE_FILE="/etc/udev/rules.d/99-battery-charge-limit.rules"

with_widget=1
restart=1
uninstall=0
limit=""

if [[ -t 1 ]]; then B=$'\e[1m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'; else B="" Y="" R="" N=""; fi
say()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
warn() { printf '%swarning:%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Install the battery charge-limit CLI and its Omarchy bar widget.

  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash -s -- [options]

Options:
  --limit <pct>   also set a charge limit and keep it at boot (e.g. 80)
  --cli-only      install just the CLI, not the Omarchy widget
  --no-restart    don't restart the Omarchy shell afterwards
  --uninstall     remove both and restore Omarchy's Power widget

Environment:
  PREFIX          where the CLI goes (default ~/.local → ~/.local/bin/battery)
  BATTERY_REF     branch or tag to install (default main)
EOF
}

while (( $# )); do
  case $1 in
    --cli-only)    with_widget=0 ;;
    --no-restart)  restart=0 ;;
    --limit)       [[ $# -ge 2 ]] || die "--limit needs a percentage"; limit=$2; shift ;;
    --limit=*)     limit=${1#*=} ;;
    --uninstall)   uninstall=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

# ------------------------------------------------------------------ omarchy

# Omarchy is installed when its CLI is; it is *running* when its shell answers.
omarchy_installed() { command -v omarchy >/dev/null && command -v omarchy-shell >/dev/null; }
omarchy_running()   { omarchy_installed && omarchy-shell shell ping >/dev/null 2>&1; }

# Wait for the shell to see a plugin directory after it changes.
wait_for_plugin() {
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  local _
  for _ in $(seq 40); do
    omarchy plugin list --json 2>/dev/null | jq -e --arg id "$1" 'any(.[]; .id == $id)' >/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# Every other enabled clone of the Power widget (e.g. one made with `omarchy plugin clone`).
other_power_clones() {
  omarchy plugin list --json 2>/dev/null | jq -r --arg src "$SOURCE_ID" --arg me "$WIDGET_ID" \
    '.[] | select(.clonedFrom == $src and .id != $me and .enabled) | .id'
}

# The bar entry's settings (showPercentage, …) for whichever Power widget is in the bar
# now, including this one when reinstalling over itself.
current_power_settings() {
  [[ -f $SHELL_JSON ]] || { echo '{}'; return; }
  jq -c --arg src "$SOURCE_ID" --arg me "$WIDGET_ID" --argjson clones "$(other_power_clones | jq -R . | jq -s .)" '
    [.bar.layout // {} | to_entries[] | .value[]?
     | select(type == "object" and (.id == $src or .id == $me or (.id as $i | $clones | index($i))))]
    | (.[0] // {}) | del(.id)' "$SHELL_JSON" 2>/dev/null || echo '{}'
}

apply_settings() {
  local settings=$1 tmp
  [[ $settings != '{}' && -f $SHELL_JSON ]] || return 0
  tmp=$(mktemp "$SHELL_JSON.XXXXXX")
  if jq --arg id "$WIDGET_ID" --argjson s "$settings" '
      .bar.layout |= with_entries(.value |= map(
        if type == "object" and .id == $id then $s + . else . end))' "$SHELL_JSON" >"$tmp"; then
    mv "$tmp" "$SHELL_JSON"
  else
    rm -f "$tmp"
    warn "could not carry over the Power widget's settings"
  fi
}

restart_shell() {
  (( restart )) || { say "Run 'omarchy restart shell' to load the change."; return; }
  say "Restarting the Omarchy shell"
  omarchy restart shell >/dev/null 2>&1 || warn "restart failed; run 'omarchy restart shell'"
}

# ---------------------------------------------------------------- uninstall

if (( uninstall )); then
  if [[ -d $WIDGET_DIR ]]; then
    if omarchy_running; then
      say "Disabling $WIDGET_ID (Omarchy restores its Power widget)"
      omarchy-shell shell setPluginEnabled "$WIDGET_ID" false >/dev/null 2>&1 || true
    fi
    say "Removing $WIDGET_DIR"
    rm -rf "$WIDGET_DIR"
    if omarchy_running; then
      omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
      restart_shell
    fi
  fi
  if [[ -f $BIN ]]; then
    say "Removing $BIN"
    rm -f "$BIN"
  fi
  [[ -f $RULE_FILE ]] && warn "a boot rule is still installed; remove it with: sudo rm $RULE_FILE"
  say "Uninstalled. The current limit stays in effect until reboot."
  exit 0
fi

# ------------------------------------------------------------------ sources
#
# From a checkout, use the files beside this script. Piped from curl there is
# no script file, so download the project archive for $REF instead.

[[ $(uname -s) == Linux ]] || die "this needs Linux (the charge limit lives in /sys/class/power_supply)"

SRC=""
script_dir=""
[[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]] && script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -n $script_dir && -f $script_dir/battery && -f $script_dir/widget/manifest.json ]]; then
  SRC=$script_dir
  say "Installing from $SRC"
else
  command -v curl >/dev/null || die "curl is required"
  command -v tar >/dev/null || die "tar is required"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  say "Downloading $REPO@$REF"
  curl -fsSL "https://github.com/$REPO/archive/$REF.tar.gz" | tar -xz -C "$tmp" --strip-components=1 \
    || die "download failed: https://github.com/$REPO/archive/$REF.tar.gz"
  [[ -f $tmp/battery && -f $tmp/widget/manifest.json ]] || die "the download is missing files"
  SRC=$tmp
fi

# ------------------------------------------------------------------ install

compgen -G "/sys/class/power_supply/*/charge_control_end_threshold" >/dev/null ||
  warn "this machine's battery does not expose a charge limit; the CLI will say so"

say "Installing the CLI to $BIN"
install -Dm755 "$SRC/battery" "$BIN"
[[ :$PATH: == *":$PREFIX/bin:"* ]] || warn "$PREFIX/bin is not on your PATH; add it to use 'battery' directly"

if (( with_widget )); then
  if ! omarchy_installed; then
    say "Omarchy not found; skipping the bar widget"
  else
    command -v jq >/dev/null || die "jq is required for the widget"
    running=0
    omarchy_running && running=1
    settings='{}'
    (( running )) && settings=$(current_power_settings)

    say "Installing the widget to $WIDGET_DIR"
    rm -rf "$WIDGET_DIR"
    mkdir -p "$WIDGET_DIR"
    cp "$SRC"/widget/{manifest.json,Panel.qml,Model.js} "$WIDGET_DIR/"
    # Point the widget at wherever the CLI went; the shell's PATH may not include it.
    sed -i "s|readonly property string batteryCli: .*|readonly property string batteryCli: \"$BIN\"|" "$WIDGET_DIR/Panel.qml"

    if (( running )); then
      for clone in $(other_power_clones); do
        say "Disabling $clone (another clone of the Power widget)"
        omarchy-shell shell setPluginEnabled "$clone" false >/dev/null 2>&1 || true
      done
      wait_for_plugin "$WIDGET_ID" || die "the Omarchy shell did not pick up $WIDGET_ID"
      say "Swapping it in for Omarchy's Power widget"
      omarchy plugin enable "$WIDGET_ID" >/dev/null
      apply_settings "$settings"
      restart_shell
    else
      # Swapping goes through the running shell; there is none (a TTY, SSH, …).
      warn "the Omarchy shell isn't running, so the widget is installed but not in the bar yet."
      warn "From your desktop, run: omarchy plugin enable $WIDGET_ID"
    fi
  fi
fi

if [[ -n $limit ]]; then
  say "Setting a $limit% charge limit (asks for your password)"
  # Piped from curl, stdin is the script: give the CLI the terminal so sudo can prompt.
  if [[ -r /dev/tty ]] && { true </dev/tty; } 2>/dev/null; then
    "$BIN" apply "$limit" </dev/tty || warn "could not set the limit; try: battery apply $limit"
  else
    "$BIN" apply "$limit" || warn "could not set the limit; try: battery apply $limit"
  fi
fi

say "Done. Run 'battery' for status$(omarchy_installed && (( with_widget )) && echo ", or click the battery in your bar")."

}

main "$@"
