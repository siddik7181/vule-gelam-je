#!/bin/bash
# One-command setup. Usage: scripts/vule.sh install|uninstall
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  install)
    osascript -e 'quit app id "dev.vule.notch"' 2>/dev/null || true
    scripts/build.sh --open
    scripts/install-claude-hooks.sh
    echo "Vule installed. Restart your Claude sessions to pick up the hooks." ;;
  uninstall)
    osascript -e 'quit app id "dev.vule.notch"' 2>/dev/null || true
    scripts/install-claude-hooks.sh --uninstall
    rm -rf build/Vule.app ~/.vule
    defaults delete dev.vule.notch 2>/dev/null || true
    echo "Vule removed. Restart your Claude sessions to drop the hooks." ;;
  *) echo "usage: $0 install|uninstall" >&2; exit 1 ;;
esac
