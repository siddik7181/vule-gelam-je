#!/bin/bash
# Adds hooks/vule-hook.sh to ~/.claude/settings.json for the events Vule needs.
# Backs up first, keeps every existing hook, and is safe to re-run. `--uninstall` removes only Vule's entries.
set -euo pipefail
cd "$(dirname "$0")/.."
hook="$PWD/hooks/vule-hook.sh"
settings="$HOME/.claude/settings.json"
chmod +x "$hook"
[ -f "$settings" ] || echo '{}' > "$settings"
cp "$settings" "$settings.vule-backup-$(date +%Y%m%d%H%M%S)"

events='["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","Notification","Stop","SubagentStop","PreCompact","SessionEnd"]'

if [ "${1:-}" = --uninstall ]; then
  jq --arg cmd "$hook" '.hooks |= (. // {} | map_values(map(select(all(.hooks[]?; .command != $cmd)))) | with_entries(select(.value | length > 0)))' \
    "$settings" > "$settings.tmp"
  echo "Removed Vule hooks."
else
  jq --arg cmd "$hook" --argjson events "$events" '
    reduce $events[] as $e (.;
      .hooks[$e] = ((.hooks[$e] // []) | map(select(all(.hooks[]?; .command != $cmd))))
                   + [{"matcher": "", "hooks": [{"type": "command", "command": $cmd, "timeout": 5}]}])' \
    "$settings" > "$settings.tmp"
  echo "Installed Vule hooks. Restart running Claude sessions to pick them up."
fi
mv "$settings.tmp" "$settings"
