# Vule

A notch island for macOS that shows which Claude Code or Copilot CLI session you're typing into, and which other sessions are busy, waiting on you, or done. You can reply to any of them from the notch.

- **Dots** beside the notch, one per session. Rings radiate from a busy dot like a signal, around a spinning comet; fast orange signal rings mean it needs you, a ring means done, and a dim dot means idle.
- **Codename** of the focused Ghostty terminal's session, named on-device by FoundationModels. The title has a glowing highlight that streams left to right, and a flowing line runs under the island while that session works.
- **Hover** the island or press **⌘⇧Space** to see every session and reply. Text is typed into the chosen terminal through Ghostty's AppleScript, so no window focus flicker. When a session asks a question (Claude's AskUserQuestion, Copilot's ask_user) or wants permission, its card shows the question and options. Click an option to answer it in the terminal; Vule presses ↓ and Enter for you. **Open ↗** jumps to the session's terminal.

**Signal:** when a session asks you something (a permission prompt or a question), rings shoot out of its dot like a signal. They also show on your other displays, and repeat every 10s, getting bigger each time (more rings, wider reach, maxing out after 30s). As soon as you look at that session (its Ghostty tab, or its card in the island opened with ⌘⇧Space or the reply box), the signal stops, even if you switch away without replying. It comes back only when the session asks something new. A finished session sends one gentler ripple.

**Themes:** right-click the island and pick Neon, Aurora, Sunset, Jewel or Pastel. You can also set your own colours, which adds a **Custom** theme to the menu:

```sh
defaults write dev.vule.notch customColors "FF0055,00E5FF,7C5CFF,FFC23D"
```

Requires macOS 26+ and Ghostty 1.4+.

## Install

```sh
scripts/build.sh --open              # builds build/Vule.app and launches it
scripts/install-claude-hooks.sh      # Claude status hooks (restart Claude sessions afterwards)
```

Copilot sessions are detected automatically from `~/.copilot/session-state`. On first reply, macOS asks for Automation permission to control Ghostty. The app is ad-hoc signed, so the permission prompt may reappear after rebuilds.

Uninstall the hooks with `scripts/install-claude-hooks.sh --uninstall`. App state lives in `~/.vule`.

## Debug

```sh
.build/release/Vule --list            # detected sessions and Ghostty terminals
.build/release/Vule --name "prompt"   # test the codenamer
.build/release/Vule --render out.png  # render the UI with sample sessions
.build/release/Vule --signal          # preview the signal burst every 3s
.build/release/Vule --selftest
```
