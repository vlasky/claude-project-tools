# claude-project-tools

A cross-platform toolset for managing Claude Code project metadata (`~/.claude/`). Handles moving projects, detecting orphaned metadata, fixing/merging orphans, and purging stale metadata.

## Structure

- `claude-move` - bash script for Linux/macOS
- `claude-move.ps1` - PowerShell script for Windows
- `claude-orphans` - bash script to find/fix orphaned projects (Linux/macOS)
- `claude-orphans.ps1` - PowerShell script to find/fix orphaned projects (Windows)

## What it does

When a project directory is moved, Claude Code loses track of it because its metadata still references the old path. Both scripts update:

1. `~/.claude/projects/<dirname>` - renames the project metadata directory
2. `~/.claude/sessions/*.json` - updates the `cwd` field
3. `~/.claude/history.jsonl` - updates `project` path references
4. Session JSONL files inside the project dir - updates `cwd` fields in messages

## Key design decisions

- Relative paths are resolved to absolute (bash uses `python3 os.path.normpath`, PowerShell uses `[System.IO.Path]::GetFullPath`)
- Claude's project directory naming scheme: all non-alphanumeric characters replaced with `-` (e.g. `/home/user/app` -> `-home-user-app`, `C:\Users\foo\app` -> `C--Users-foo-app`)
- Replacements are boundary-aware: paths must be surrounded by quotes to avoid partial matches (e.g. `/app` won't match `/app-backup`)
- On Windows, paths in JSON are stored with escaped backslashes (`C:\\Users\\...`), so the PowerShell script matches and replaces the escaped form
- Both scripts back up all files before modification and roll back on any failure
- Both refuse to run if Claude Code has an active session for the project (checks PID liveness)
- Does not use `mv`-style "move into directory" semantics - if the destination is an existing directory, it suggests the explicit path instead

## Platform differences

| | Linux/macOS (`claude-move`) | Windows (`claude-move.ps1`) |
|---|---|---|
| Config location | `~/.claude/` | `%USERPROFILE%\.claude\` |
| Path in JSON | `/home/user/app` | `C:\\Users\\user\\app` (escaped backslashes) |
| Dirname encoding | `/` → `-` | all `[^a-zA-Z0-9]` → `-` (`:` and `\` each become `-`) |
| Dependencies | bash, sed, grep, mktemp | PowerShell 5.1+ |

## claude-orphans

Detects orphaned projects (metadata exists but project directory is missing) and can fix them.

### Detection

Scans each directory in `~/.claude/projects/` and determines the original project path by:
1. Extracting `cwd` from JSONL session files inside the metadata directory
2. Cross-referencing session JSON files whose dirname matches
3. Cross-referencing `history.jsonl` project fields

If the resolved path doesn't exist on disk, the project is orphaned.

### Fixing

`claude-orphans fix <old-path> <new-path>` delegates to `claude-move --metadata-only` after verifying:
- The old path has metadata (is a known project)
- The old path doesn't exist on disk (is actually orphaned)
- The new path exists on disk (is a valid target)

If the new path already has its own metadata (because Claude was used there), the fix merges session files and memory from the orphan into the existing metadata rather than failing.

### Purging

`claude-orphans purge <path>` permanently deletes an orphan's metadata after confirmation:
- Removes the project metadata directory
- Deletes associated session JSON files
- Removes history.jsonl entries

`claude-orphans purge --all` purges all detected orphans at once (single confirmation prompt).

Safety: refuses to purge if the path still exists on disk. Shows session count and memory presence before confirming. Use `-y`/`--yes`/`-Yes` to skip prompts.

## Testing

Use `--dry-run` / `-DryRun` to preview changes without modifying anything. Combine with `--metadata-only` / `-MetadataOnly` to skip the directory move.
