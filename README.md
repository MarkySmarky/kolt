# kolt

A fork of [cmux](https://github.com/manaflow-ai/cmux) that adds a live diff viewer, git worktree management, and CI status awareness.

Built on Ghostty (libghostty), Swift/AppKit, macOS 14+.

## Download

| | |
|---|---|
| **Apple Silicon** (M1/M2/M3/M4) | [kolt-macos-apple-silicon.dmg](releases/kolt-macos-apple-silicon.dmg) |

Open the `.dmg` and drag Kolt to Applications. On first launch, right-click → Open to bypass Gatekeeper (the app is not notarized).

## What's added

**DiffPanel** (`Cmd+Shift+K`) — VS Code-style source control panel as a split pane. Staged/unstaged sections with per-file stage/discard actions, resizable file tree, live-updating diffs via FSEvents.

**Worktree Management** (`Cmd+N`) — New Workspace dialog with three modes: new branch (from any base), existing branch, or empty workspace. Worktrees are created behind the scenes. Sidebar WORKTREES section shows all active worktrees with merged/stale detection and inline delete.

**CI Status** — GitHub Actions status in the sidebar per workspace. Polls via `gh` CLI, integrates with existing PR status. Click to open the Actions run.

## Build from source

Requires macOS 14+, Xcode 15+, Zig.

```bash
brew install zig
git clone --recursive git@github.com:MarkySmarky/kolt.git
cd kolt
./scripts/setup.sh
./scripts/reload.sh --tag dev --launch
```

## License

AGPL-3.0 — same as upstream cmux. See [NOTICE](NOTICE) for details.
