# claude-project-tools

![Version](https://img.shields.io/badge/version-1.0.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey)
![Shell](https://img.shields.io/badge/shell-Bash%20%7C%20PowerShell-orange)

Manage Claude Code project metadata without losing your session history.

When you move or delete a project folder, Claude Code loses track of it because its internal metadata still references the old path. This toolset keeps everything in sync.

## Tools

| Tool | Purpose |
|------|---------|
| `claude-move` | Move a project directory and update all metadata |
| `claude-orphans` | Find, fix, or purge orphaned project metadata |

## Installation

### Linux / macOS

```bash
# Clone the repo
git clone https://github.com/vlasky/claude-project-tools.git
cd claude-project-tools

# Symlink into your PATH
ln -s "$(pwd)/claude-move" ~/.local/bin/claude-move
ln -s "$(pwd)/claude-orphans" ~/.local/bin/claude-orphans
```

### Windows

Copy `claude-move.ps1`, `claude-move.bat`, and `claude-orphans.ps1` somewhere in your PATH, or run directly from the project directory.

## claude-move

```
claude-move <old-path> <new-path>
```

Moves the project directory and updates Claude Code's metadata in one step. Paths can be relative or absolute.

### Options

| Option | Description |
|--------|-------------|
| `--metadata-only` / `-MetadataOnly` | Only update metadata (directory already moved) |
| `--dry-run` / `-DryRun` | Preview changes without modifying anything |
| `--help` / `-Help` | Show usage information |

### Examples

```bash
# Move a project to a new location
claude-move ~/projects/myapp ~/work/myapp

# Already moved the folder? Just fix the metadata
claude-move --metadata-only /old/path /new/path

# Preview what would change
claude-move --dry-run ~/projects/myapp ~/work/myapp
```

## claude-orphans

```
claude-orphans              # List orphaned projects
claude-orphans fix <old> <new>   # Repoint an orphan to its new location
claude-orphans purge <path>      # Delete an orphan's metadata
claude-orphans purge --all       # Delete all orphaned metadata
```

### Options

| Option | Description |
|--------|-------------|
| `--dry-run` / `-DryRun` | Preview changes without modifying anything |
| `-y` / `--yes` / `-Yes` | Skip confirmation prompts |
| `--help` / `-Help` | Show usage information |

### Examples

```bash
# See what's orphaned
claude-orphans

# Project moved? Point the metadata to the new location
claude-orphans fix /old/project/path /new/project/path

# Project deleted? Remove stale metadata
claude-orphans purge /deleted/project/path

# Clean up everything at once
claude-orphans purge --all
```

## What gets updated

1. `~/.claude/projects/<dirname>` - renames/removes the project metadata directory
2. `~/.claude/sessions/*.json` - updates or removes session references
3. `~/.claude/history.jsonl` - updates or removes project path entries
4. Session JSONL files - updates `cwd` fields in conversation messages

## Safety features

- **Dry run mode** - preview all changes before applying them
- **Backup and rollback** - all files are backed up before modification; if anything fails, changes are automatically reverted (claude-move)
- **Active session detection** - refuses to run if Claude Code is currently using the project
- **Boundary-aware matching** - won't accidentally modify paths that share a common prefix (e.g. moving `/app` won't affect `/app-backup`)
- **Purge confirmation** - shows what will be lost (session count, memory presence) and requires explicit confirmation
- **Orphan validation** - refuses to purge or fix paths that still exist on disk

## Requirements

- **Linux/macOS**: bash, sed, grep, mktemp (standard on all Unix systems)
- **Windows**: PowerShell 5.1+ (included with Windows 10/11)

## License

MIT
