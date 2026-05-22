<#
.SYNOPSIS
    Moves a Claude Code project directory and updates internal metadata.

.DESCRIPTION
    When a project directory is moved, Claude Code loses track of it because
    its metadata still references the old path. This script updates:
    - ~/.claude/projects/<dirname> (renames the project metadata directory)
    - ~/.claude/sessions/*.json (updates the cwd field)
    - ~/.claude/history.jsonl (updates project path references)
    - Session JSONL files (updates cwd fields in messages)

.EXAMPLE
    claude-move.ps1 C:\Users\me\projects\myapp C:\Users\me\work\myapp

.EXAMPLE
    claude-move.ps1 -MetadataOnly -DryRun .\old-project .\new-project
#>

param(
    [switch]$MetadataOnly,
    [switch]$DryRun,
    [switch]$Help,
    [Parameter(Position=0)]
    [string]$OldPath,
    [Parameter(Position=1)]
    [string]$NewPath
)

function Show-Usage {
    Write-Host @"
Usage: claude-move.ps1 <old-path> <new-path>

Moves a project directory and updates Claude Code's internal metadata
to reflect the new location.

Paths can be relative or absolute. The old path must exist (or use
-MetadataOnly to update metadata without moving files).

Options:
  -MetadataOnly   Only update Claude Code metadata (don't move the directory)
  -DryRun         Show what would be changed without making modifications
  -Help           Show this help message

Examples:
  claude-move.ps1 C:\Users\me\projects\myapp C:\Users\me\work\myapp
  claude-move.ps1 -MetadataOnly C:\old\path C:\new\path
  claude-move.ps1 -DryRun .\myapp ..\work\myapp
"@
    exit 0
}

if ($Help) { Show-Usage }

if (-not $OldPath -or -not $NewPath) { Show-Usage }

# Resolve to absolute paths and normalize
$OldPath = [System.IO.Path]::GetFullPath($OldPath).TrimEnd('\', '/')
$NewPath = [System.IO.Path]::GetFullPath($NewPath).TrimEnd('\', '/')

if ($OldPath -eq $NewPath) {
    Write-Error "Old and new paths are the same"
    exit 1
}

$ClaudeDir = Join-Path $env:USERPROFILE ".claude"
if (-not (Test-Path $ClaudeDir)) {
    Write-Error "~/.claude directory not found at: $ClaudeDir"
    exit 1
}

# Convert path to Claude's directory naming scheme: all non-alphanumeric chars become -
function ConvertTo-ClaudeDirname {
    param([string]$Path)
    return ($Path -replace '[^a-zA-Z0-9]', '-')
}

# Check if Claude Code is running for the given project
function Test-ClaudeRunning {
    param([string]$Path)

    $SessionsDir = Join-Path $ClaudeDir "sessions"
    if (-not (Test-Path $SessionsDir)) { return }

    foreach ($file in Get-ChildItem "$SessionsDir\*.json" -ErrorAction SilentlyContinue) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        try {
            $session = $content | ConvertFrom-Json
        } catch { continue }

        if ($session.cwd -eq $Path -or $session.cwd -eq $Path.Replace('\', '/')) {
            $pid_val = $session.pid
            if ($pid_val) {
                $proc = Get-Process -Id $pid_val -ErrorAction SilentlyContinue
                if ($proc) {
                    Write-Error "Claude Code appears to be running for this project (PID: $pid_val)`nPlease close Claude Code sessions for this project before moving."
                    exit 1
                }
            }
        }
    }
}

# --- Backup and rollback ---

$script:BackupDir = $null
$script:BackupManifest = @()
$script:DirMoved = $false

function New-BackupDir {
    $script:BackupDir = Join-Path ([System.IO.Path]::GetTempPath()) "claude-move-backup-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
}

function Backup-File {
    param([string]$FilePath)

    if (-not $script:BackupDir) { New-BackupDir }
    $backupName = $FilePath.Replace('\', '__').Replace('/', '__').Replace(':', '_')
    $dest = Join-Path $script:BackupDir $backupName
    Copy-Item $FilePath $dest -Force
    $script:BackupManifest += @{ Original = $FilePath; Backup = $dest }
}

function Invoke-Rollback {
    Write-Host ""
    Write-Error "Error occurred - rolling back changes..."

    foreach ($entry in $script:BackupManifest) {
        if (Test-Path $entry.Backup) {
            Copy-Item $entry.Backup $entry.Original -Force
            Write-Host "  Restored: $($entry.Original)"
        }
    }

    # Undo project directory rename
    $oldProjDir = Join-Path $ProjectsDir $OldDirname
    $newProjDir = Join-Path $ProjectsDir $NewDirname
    if ((Test-Path $newProjDir) -and -not (Test-Path $oldProjDir)) {
        Rename-Item $newProjDir $OldDirname
        Write-Host "  Restored: projects/$OldDirname"
    }

    # Undo file move
    if ($script:DirMoved -and (Test-Path $NewPath) -and -not (Test-Path $OldPath)) {
        Move-Item $NewPath $OldPath
        Write-Host "  Restored: $OldPath"
    }

    Remove-BackupDir
}

function Remove-BackupDir {
    if ($script:BackupDir -and (Test-Path $script:BackupDir)) {
        Remove-Item $script:BackupDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Main logic ---

$OldDirname = ConvertTo-ClaudeDirname $OldPath
$NewDirname = ConvertTo-ClaudeDirname $NewPath
$ProjectsDir = Join-Path $ClaudeDir "projects"

# In JSON files, backslashes are escaped as \\, so we need both forms for matching
$OldPathJson = $OldPath.Replace('\', '\\')
$NewPathJson = $NewPath.Replace('\', '\\')

Write-Host "Claude Code Project Mover"
Write-Host "========================="
Write-Host "Old path: $OldPath"
Write-Host "New path: $NewPath"
Write-Host ""

if ($DryRun) {
    Write-Host "[DRY RUN MODE - no changes will be made]"
    Write-Host ""
}

# Pre-flight checks
if (-not $DryRun) {
    Test-ClaudeRunning $OldPath
}

# Check for metadata collision
$newProjDir = Join-Path $ProjectsDir $NewDirname
if (Test-Path $newProjDir) {
    Write-Error "Metadata already exists for destination path: $newProjDir`nIf you previously had a project at the new path, remove its metadata first."
    exit 1
}

# Step 1: Move the actual directory
if (-not $MetadataOnly) {
    if (-not (Test-Path $OldPath)) {
        Write-Error "Source directory does not exist: $OldPath"
        exit 1
    }
    if (Test-Path $NewPath) {
        if (Test-Path $NewPath -PathType Container) {
            $suggested = Join-Path $NewPath (Split-Path $OldPath -Leaf)
            Write-Error "Destination is an existing directory: $NewPath`nDid you mean: claude-move.ps1 $OldPath $suggested"
        } else {
            Write-Error "Destination already exists: $NewPath"
        }
        exit 1
    }

    $newParent = Split-Path $NewPath -Parent
    if (-not (Test-Path $newParent)) {
        Write-Error "Parent directory of destination does not exist: $newParent"
        exit 1
    }

    if ($DryRun) {
        Write-Host "[Would move] $OldPath -> $NewPath"
    } else {
        Move-Item $OldPath $NewPath
        $script:DirMoved = $true
        Write-Host "[Moved] $OldPath -> $NewPath"
    }
} else {
    Write-Host "[Metadata-only mode: skipping directory move]"
}
Write-Host ""

$changes = 0

# Wrap remaining operations in try/catch for rollback
try {

# Step 2: Rename the project directory under ~/.claude/projects/
$oldProjDir = Join-Path $ProjectsDir $OldDirname
if (Test-Path $oldProjDir) {
    if ($DryRun) {
        Write-Host "[Would rename] projects/$OldDirname -> projects/$NewDirname"
    } else {
        foreach ($f in Get-ChildItem "$oldProjDir\*.jsonl" -ErrorAction SilentlyContinue) {
            Backup-File $f.FullName
        }
        Rename-Item $oldProjDir $NewDirname
        Write-Host "[Renamed] projects/$OldDirname -> projects/$NewDirname"
    }
    $changes++
}

# Handle sub-project directories
foreach ($dir in Get-ChildItem "$ProjectsDir\$OldDirname-*" -Directory -ErrorAction SilentlyContinue) {
    $suffix = $dir.Name.Substring($OldDirname.Length)
    $newName = "$NewDirname$suffix"

    if (Test-Path (Join-Path $ProjectsDir $newName)) {
        Write-Warning "Skipping sub-project rename, destination exists: projects/$newName"
        continue
    }

    if ($DryRun) {
        Write-Host "[Would rename] projects/$($dir.Name) -> projects/$newName"
    } else {
        foreach ($f in Get-ChildItem "$($dir.FullName)\*.jsonl" -ErrorAction SilentlyContinue) {
            Backup-File $f.FullName
        }
        Rename-Item $dir.FullName $newName
        Write-Host "[Renamed] projects/$($dir.Name) -> projects/$newName"
    }
    $changes++
}

# Step 3: Update session files (cwd field)
$SessionsDir = Join-Path $ClaudeDir "sessions"
if (Test-Path $SessionsDir) {
    foreach ($file in Get-ChildItem "$SessionsDir\*.json" -ErrorAction SilentlyContinue) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        if ($content.Contains("`"$OldPathJson`"")) {
            if ($DryRun) {
                Write-Host "[Would update] sessions/$($file.Name)"
            } else {
                Backup-File $file.FullName
                $content = $content.Replace("`"$OldPathJson`"", "`"$NewPathJson`"")
                Set-Content $file.FullName $content -NoNewline
                Write-Host "[Updated] sessions/$($file.Name)"
            }
            $changes++
        }
    }
}

# Step 4: Update history.jsonl
$HistoryFile = Join-Path $ClaudeDir "history.jsonl"
if (Test-Path $HistoryFile) {
    $content = Get-Content $HistoryFile -Raw -ErrorAction SilentlyContinue
    if ($content -and $content.Contains("`"$OldPathJson`"")) {
        if ($DryRun) {
            $count = (Select-String -Path $HistoryFile -Pattern ([regex]::Escape("`"$OldPathJson`"")) -AllMatches | ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum
            Write-Host "[Would update] history.jsonl ($count occurrences)"
        } else {
            Backup-File $HistoryFile
            $content = $content.Replace("`"$OldPathJson`"", "`"$NewPathJson`"")
            Set-Content $HistoryFile $content -NoNewline
            $count = (Select-String -Path $HistoryFile -Pattern ([regex]::Escape("`"$NewPathJson`"")) -AllMatches | ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum
            Write-Host "[Updated] history.jsonl ($count occurrences updated)"
        }
        $changes++
    }
}

# Step 5: Update cwd references inside session JSONL files
$targetProjDir = if ($DryRun) { Join-Path $ProjectsDir $OldDirname } else { Join-Path $ProjectsDir $NewDirname }

if (Test-Path $targetProjDir) {
    foreach ($file in Get-ChildItem "$targetProjDir\*.jsonl" -ErrorAction SilentlyContinue) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        if ($content.Contains("`"$OldPathJson`"") -or $content.Contains("`"$OldPathJson/") -or $content.Contains("`"$OldPathJson\\")) {
            if ($DryRun) {
                Write-Host "[Would update] project session: $($file.Name)"
            } else {
                # Backup already taken before directory rename
                $content = $content.Replace("`"$OldPathJson`"", "`"$NewPathJson`"")
                $content = $content.Replace("`"$OldPathJson/", "`"$NewPathJson/")
                $content = $content.Replace("`"$OldPathJson\\", "`"$NewPathJson\\")
                Set-Content $file.FullName $content -NoNewline
                Write-Host "[Updated] project session: $($file.Name)"
            }
            $changes++
        }
    }
}

# Also update sub-project session files
$subProjPattern = if ($DryRun) { "$OldDirname-*" } else { "$NewDirname-*" }
foreach ($dir in Get-ChildItem "$ProjectsDir\$subProjPattern" -Directory -ErrorAction SilentlyContinue) {
    foreach ($file in Get-ChildItem "$($dir.FullName)\*.jsonl" -ErrorAction SilentlyContinue) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        if ($content.Contains("`"$OldPathJson`"") -or $content.Contains("`"$OldPathJson/") -or $content.Contains("`"$OldPathJson\\")) {
            if ($DryRun) {
                Write-Host "[Would update] sub-project session: $($dir.Name)/$($file.Name)"
            } else {
                $content = $content.Replace("`"$OldPathJson`"", "`"$NewPathJson`"")
                $content = $content.Replace("`"$OldPathJson/", "`"$NewPathJson/")
                $content = $content.Replace("`"$OldPathJson\\", "`"$NewPathJson\\")
                Set-Content $file.FullName $content -NoNewline
                Write-Host "[Updated] sub-project session: $($dir.Name)/$($file.Name)"
            }
            $changes++
        }
    }
}

} catch {
    if (-not $DryRun) {
        Invoke-Rollback
        exit 1
    }
    throw
}

# Success - clean up backups
if (-not $DryRun) {
    Remove-BackupDir
}

Write-Host ""
if ($DryRun) {
    Write-Host "Dry run complete. $changes change(s) would be made."
} else {
    if ($changes -eq 0) {
        Write-Host "No Claude Code metadata found for $OldPath"
    } else {
        Write-Host "Done. $changes update(s) applied."
        Write-Host "You can now open Claude Code in $NewPath and resume your sessions."
    }
}
