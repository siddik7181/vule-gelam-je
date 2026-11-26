#!/bin/sh
# Claude Code hook → ~/.vule/claude/<session_id>.json, which Vule reads to show that session in the notch.
# Records state (event, cwd, transcript path, tty) plus a pending AskUserQuestion so it can be answered
# from the notch — never prompt or response text.
d="$HOME/.vule/claude"
mkdir -p "$d"
in=$(cat)
sid=$(printf '%s' "$in" | jq -r '.session_id // empty')
[ -n "$sid" ] || exit 0
case "$sid" in */* | *..*) exit 0 ;; esac

if [ "$(printf '%s' "$in" | jq -r .hook_event_name)" = SessionEnd ]; then
  rm -f "$d/$sid.json"
  exit 0
fi

# The hook shares Claude's controlling terminal — that tty is how Vule finds the Ghostty split.
tty=$(ps -o tty= -p $$ | tr -d ' ')
case "$tty" in ''|'??') tty=$(ps -o tty= -p "$PPID" | tr -d ' ') ;; esac

printf '%s' "$in" | jq -c --arg tty "/dev/$tty" --argjson ts "$(date +%s)" \
  '{session_id, cwd, transcript_path, event: .hook_event_name, tool_name, notification_type, message, tty: $tty, ts: $ts,
    question: (if .tool_name == "AskUserQuestion" then (.tool_input.questions[0] | {text: .question, options: [.options[]?.label]}) else null end)}' \
  > "$d/$sid.json.tmp" && mv "$d/$sid.json.tmp" "$d/$sid.json"
exit 0
