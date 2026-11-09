#!/usr/bin/env bash
# Install (or uninstall) the battery CLI and its Omarchy bar widget.
#
#   ./install.sh                 CLI + widget, swaps it in for Omarchy's Power widget
#   ./install.sh --cli-only      just the CLI
#   ./install.sh --limit 80      also set an 80% limit and keep it at boot
#   ./install.sh --uninstall     remove both and restore Omarchy's Power widget
#
# PREFIX (default ~/.local) chooses where the CLI goes: $PREFIX/bin/battery.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX=${PREFIX:-$HOME/.local}
BIN="$PREFIX/bin/battery"
WIDGET_ID="battery.power"
SOURCE_ID="omarchy.power"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
WIDGET_DIR="$PLUGINS_DIR/$WIDGET_ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"

with_widget=1
restart=1
uninstall=0
limit=""

say()  { printf '\e[1m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[33mwarning:\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[31merror:\e[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

while (( $# )); do
  case $1 in
    --cli-only)    with_widget=0 ;;
    --no-restart)  restart=0 ;;
    --limit)       limit=${2:?--limit needs a percentage}; shift ;;
    --uninstall)   uninstall=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

have_omarchy() { command -v omarchy >/dev/null && command -v omarchy-shell >/dev/null; }

# Wait for the shell to see a plugin directory after it changes.
wait_for_plugin() {
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
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

# The bar entry's settings (showPercentage, …) for whichever Power widget is in the bar now.
current_power_settings() {
  [[ -f $SHELL_JSON ]] || { echo '{}'; return; }
  jq -c --arg src "$SOURCE_ID" --argjson clones "$(other_power_clones | jq -R . | jq -s .)" '
    [.bar.layout // {} | to_entries[] | .value[]?
     | select(type == "object" and (.id == $src or (.id as $i | $clones | index($i))))]
    | (.[0] // {}) | del(.id)' "$SHELL_JSON"
}

apply_settings() {
  local settings=$1
  [[ $settings != '{}' && -f $SHELL_JSON ]] || return 0
  local tmp
  tmp=$(mktemp "$SHELL_JSON.XXXXXX")
  jq --arg id "$WIDGET_ID" --argjson s "$settings" '
    .bar.layout |= with_entries(.value |= map(
      if type == "object" and .id == $id then $s + . else . end))' "$SHELL_JSON" >"$tmp" \
    && mv "$tmp" "$SHELL_JSON" || { rm -f "$tmp"; warn "could not carry over widget settings"; }
}

restart_shell() {
  (( restart )) || { say "Run 'omarchy restart shell' to load the change."; return; }
  say "Restarting the Omarchy shell"
  omarchy restart shell >/dev/null 2>&1 || warn "restart failed; run 'omarchy restart shell'"
}

# ------------------------------------------------------------------ uninstall

if (( uninstall )); then
  if [[ -d $WIDGET_DIR ]]; then
    if have_omarchy; then
      say "Disabling $WIDGET_ID (Omarchy restores its Power widget)"
      omarchy-shell shell setPluginEnabled "$WIDGET_ID" false >/dev/null 2>&1 || true
    fi
    rm -rf "$WIDGET_DIR"
    have_omarchy && { omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true; restart_shell; }
  fi
  if [[ -f $BIN ]]; then
    say "Removing $BIN"
    rm -f "$BIN"
  fi
  [[ -f /etc/udev/rules.d/99-battery-charge-limit.rules ]] &&
    warn "a boot rule is still installed: run 'sudo rm /etc/udev/rules.d/99-battery-charge-limit.rules' to drop it"
  say "Uninstalled. The current limit stays in effect until reboot."
  exit 0
fi

# -------------------------------------------------------------------- install

compgen -G "/sys/class/power_supply/*/charge_control_end_threshold" >/dev/null ||
  warn "this machine's battery does not expose a charge limit; the CLI will report that"

say "Installing CLI to $BIN"
install -Dm755 "$HERE/battery" "$BIN"
[[ :$PATH: == *":$PREFIX/bin:"* ]] || warn "$PREFIX/bin is not on your PATH"

if (( with_widget )); then
  if ! have_omarchy; then
    warn "Omarchy not found; skipping the bar widget"
  else
    command -v jq >/dev/null || die "jq is required for the widget install"
    settings=$(current_power_settings)

    say "Installing widget to $WIDGET_DIR"
    rm -rf "$WIDGET_DIR"
    mkdir -p "$WIDGET_DIR"
    cp "$HERE"/widget/{manifest.json,Panel.qml,Model.js} "$WIDGET_DIR/"
    # Point the widget at wherever the CLI went; the shell's PATH may not include it.
    sed -i "s|readonly property string batteryCli: .*|readonly property string batteryCli: \"$BIN\"|" "$WIDGET_DIR/Panel.qml"

    for clone in $(other_power_clones); do
      say "Disabling $clone (another clone of the Power widget)"
      omarchy-shell shell setPluginEnabled "$clone" false >/dev/null 2>&1 || true
    done

    wait_for_plugin "$WIDGET_ID" || die "the shell did not pick up $WIDGET_ID"
    say "Swapping it in for Omarchy's Power widget"
    omarchy plugin enable "$WIDGET_ID" >/dev/null
    apply_settings "$settings"
    restart_shell
  fi
fi

if [[ -n $limit ]]; then
  say "Setting a $limit% charge limit (asks for your password)"
  "$BIN" apply "$limit"
fi

say "Done. Run 'battery' for status, or open the battery panel in the bar."
