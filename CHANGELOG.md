# Changelog

## 1.0.0 - 2026-05-22

### Added

- `claude-move` - move project directories and update Claude Code metadata (bash + PowerShell)
- `claude-move.bat` - Windows cmd.exe wrapper for claude-move.ps1
- `claude-orphans` - detect, fix, and purge orphaned project metadata (bash + PowerShell)
- Orphan detection: scans `~/.claude/projects/` for metadata with no matching directory on disk
- Orphan fix: repoints metadata to a new location, with merge support when the destination already has its own metadata
- Orphan purge: permanently removes stale metadata with interactive confirmation
- `--dry-run` support across all commands
- Backup and automatic rollback on failure (claude-move)
- Active session detection (refuses to modify projects with a running Claude Code session)
- Boundary-aware path replacement (prevents partial-match corruption)
