<#
.SYNOPSIS
    Finds orphaned Claude Code projects and optionally repoints or purges their metadata.

.DESCRIPTION
    Scans ~/.claude/projects/ for project metadata directories whose corresponding
    project directory no longer exists on disk. Can fix orphans by repointing
    their metadata to a new location, or purge them entirely.

.EXAMPLE
    claude-orphans.ps1

.EXAMPLE
    claude-orphans.ps1 fix C:\Users\me\old-project C:\Users\me\new-location

.EXAMPLE
    claude-orphans.ps1 purge C:\Users\me\deleted-project

.EXAMPLE
    claude-orphans.ps1 purge --all

.EXAMPLE
    claude-orphans.ps1 -DryRun fix C:\old\path C:\new\path
#>

param(
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Help,
    [Parameter(Position=0)]
    [string]$Command,
    [Parameter(Position=1)]
    [string]$OldPath,
    [Parameter(Position=2)]
    [string]$NewPath
)

function Show-Usage {
    Write-Host @"
Usage: claude-orphans.ps1 [options]
       claude-orphans.ps1 fix <old-path> <new-path>
       claude-orphans.ps1 purge <path>
       claude-orphans.ps1 purge --all

Finds orphaned Claude Code projects - those with metadata in ~/.claude/projects/
but no corresponding directory on disk.

Commands:
  (none)                   List all orphaned projects
  fix <old-path> <new>     Repoint an orphan's metadata to a new location
  purge <path>             Delete an orphan's metadata permanently
  purge --all              Delete all orphaned project metadata

Options:
  -DryRun      Preview what would be changed without making modifications
  -Yes         Skip confirmation prompts
  -Help        Show this help message

Examples:
  claude-orphans.ps1
  claude-orphans.ps1 fix C:\Users\me\old-project C:\Users\me\new-location
  claude-orphans.ps1 -DryRun fix C:\old\path C:\new\path
  claude-orphans.ps1 purge C:\Users\me\deleted-project
  claude-orphans.ps1 purge --all
"@
    exit 0
}

if ($Help) { Show-Usage }

$ClaudeDir = Join-Path $env:USERPROFILE ".claude"
$ProjectsDir = Join-Path $ClaudeDir "projects"

if (-not (Test-Path $ClaudeDir)) {
    Write-Error "~/.claude directory not found at: $ClaudeDir"
    exit 1
}

if (-not (Test-Path $ProjectsDir)) {
    Write-Host "No projects directory found at $ProjectsDir"
    exit 0
}

function ConvertTo-ClaudeDirname {
    param([string]$Path)
    return ($Path -replace '[^a-zA-Z0-9]', '-')
}

function Get-ProjectPath {
    param([string]$ProjDir)

    $dirname = Split-Path $ProjDir -Leaf

    # Look inside JSONL files for cwd references
    foreach ($jsonl in Get-ChildItem "$ProjDir\*.jsonl" -ErrorAction SilentlyContinue) {
        $content = Get-Content $jsonl.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        if ($content -match '"cwd"\s*:\s*"([^"]+)"') {
            $candidate = $Matches[1] -replace '\\\\', '\'
            return $candidate
        }
    }

    # Check session JSON files
    $sessionsDir = Join-Path $ClaudeDir "sessions"
    if (Test-Path $sessionsDir) {
        foreach ($file in Get-ChildItem "$sessionsDir\*.json" -ErrorAction SilentlyContinue) {
            $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }
            if ($content -match '"cwd"\s*:\s*"([^"]+)"') {
                $candidate = $Matches[1] -replace '\\\\', '\'
                $checkDirname = ConvertTo-ClaudeDirname $candidate
                if ($checkDirname -eq $dirname) {
                    return $candidate
                }
            }
        }
    }

    # Check history.jsonl
    $historyFile = Join-Path $ClaudeDir "history.jsonl"
    if (Test-Path $historyFile) {
        $lines = Get-Content $historyFile -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            if ($line -match '"project"\s*:\s*"([^"]+)"') {
                $candidate = $Matches[1] -replace '\\\\', '\'
                $checkDirname = ConvertTo-ClaudeDirname $candidate
                if ($checkDirname -eq $dirname) {
                    return $candidate
                }
            }
        }
    }

    return $null
}

function Show-Orphans {
    $found = 0

    foreach ($projDir in Get-ChildItem $ProjectsDir -Directory -ErrorAction SilentlyContinue) {
        $dirname = $projDir.Name
        $projectPath = Get-ProjectPath $projDir.FullName

        if (-not $projectPath) {
            Write-Host "[unknown]  $dirname (could not determine original path)"
            $found++
            continue
        }

        if (-not (Test-Path $projectPath)) {
            Write-Host "[orphaned] $projectPath"
            Write-Host "           metadata: projects/$dirname"
            $found++
        }
    }

    Write-Host ""
    if ($found -eq 0) {
        Write-Host "No orphaned projects found."
    } else {
        Write-Host "$found orphaned project(s) found."
        Write-Host "Use 'claude-orphans.ps1 fix <old-path> <new-path>' to repoint metadata."
        Write-Host "Use 'claude-orphans.ps1 purge <path>' to delete metadata permanently."
    }
}

function Invoke-Fix {
    if (-not $OldPath -or -not $NewPath) {
        Write-Error "'fix' requires two arguments: <old-path> <new-path>"
        exit 1
    }

    $resolvedOld = [System.IO.Path]::GetFullPath($OldPath).TrimEnd('\', '/')
    $resolvedNew = [System.IO.Path]::GetFullPath($NewPath).TrimEnd('\', '/')

    if ($resolvedOld -eq $resolvedNew) {
        Write-Error "Old and new paths are the same"
        exit 1
    }

    $oldDirname = ConvertTo-ClaudeDirname $resolvedOld
    $newDirname = ConvertTo-ClaudeDirname $resolvedNew
    $oldProjDir = Join-Path $ProjectsDir $oldDirname
    $newProjDir = Join-Path $ProjectsDir $newDirname

    if (-not (Test-Path $oldProjDir)) {
        Write-Error "No metadata found for path: $resolvedOld`n  (expected directory: $oldProjDir)"
        exit 1
    }

    if (Test-Path $resolvedOld) {
        Write-Error "$resolvedOld still exists on disk - this is not an orphan`nUse 'claude-move.ps1' instead to move an existing project."
        exit 1
    }

    if (-not (Test-Path $resolvedNew)) {
        Write-Error "New path does not exist: $resolvedNew`nThe new path must be an existing directory."
        exit 1
    }

    # If destination has no existing metadata, delegate to claude-move
    if (-not (Test-Path $newProjDir)) {
        $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
        $moveScript = Join-Path $scriptDir "claude-move.ps1"

        if (-not (Test-Path $moveScript)) {
            Write-Error "claude-move.ps1 not found at $moveScript"
            exit 1
        }

        $moveArgs = @("-MetadataOnly")
        if ($DryRun) { $moveArgs += "-DryRun" }
        $moveArgs += $resolvedOld
        $moveArgs += $resolvedNew

        & $moveScript @moveArgs
        return
    }

    # --- Destination already has metadata: merge ---

    $oldPathJson = $resolvedOld.Replace('\', '\\')
    $newPathJson = $resolvedNew.Replace('\', '\\')

    Write-Host "Claude Code Orphan Fix (merge mode)"
    Write-Host "===================================="
    Write-Host "Orphan path:  $resolvedOld"
    Write-Host "New path:     $resolvedNew"
    Write-Host ""
    Write-Host "Destination already has metadata - merging orphan's sessions into it."
    Write-Host ""

    if ($DryRun) {
        Write-Host "[DRY RUN MODE - no changes will be made]"
        Write-Host ""
    }

    $changes = 0

    # Step 1: Merge session JSONL files from orphan into destination
    foreach ($jsonl in Get-ChildItem "$oldProjDir\*.jsonl" -ErrorAction SilentlyContinue) {
        if ($DryRun) {
            if (Test-Path (Join-Path $newProjDir $jsonl.Name)) {
                Write-Host "[Would merge] $($jsonl.Name) (exists in both - orphan's copy will be renamed)"
            } else {
                Write-Host "[Would move]  $($jsonl.Name) -> projects/$newDirname/"
            }
        } else {
            # Rewrite old paths to new paths in the file
            $content = Get-Content $jsonl.FullName -Raw
            if ($content) {
                $content = $content.Replace("`"$oldPathJson`"", "`"$newPathJson`"")
                $content = $content.Replace("`"$oldPathJson/", "`"$newPathJson/")
                $content = $content.Replace("`"$oldPathJson\\", "`"$newPathJson\\")
            }

            $targetPath = Join-Path $newProjDir $jsonl.Name
            if (Test-Path $targetPath) {
                $targetPath = Join-Path $newProjDir "merged-$($jsonl.Name)"
                Set-Content $targetPath $content -NoNewline
                Remove-Item $jsonl.FullName
                Write-Host "[Merged] $($jsonl.Name) -> merged-$($jsonl.Name)"
            } else {
                Set-Content $targetPath $content -NoNewline
                Remove-Item $jsonl.FullName
                Write-Host "[Moved]  $($jsonl.Name) -> projects/$newDirname/"
            }
        }
        $changes++
    }

    # Step 1b: Merge memory directory if present
    $oldMemDir = Join-Path $oldProjDir "memory"
    $newMemDir = Join-Path $newProjDir "memory"
    if (Test-Path $oldMemDir) {
        if ($DryRun) {
            Write-Host "[Would merge] memory/"
        } else {
            if (-not (Test-Path $newMemDir)) {
                Move-Item $oldMemDir $newMemDir
                Write-Host "[Moved]  memory/ -> projects/$newDirname/memory/"
            } else {
                foreach ($memFile in Get-ChildItem "$oldMemDir\*" -File -ErrorAction SilentlyContinue) {
                    $destMem = Join-Path $newMemDir $memFile.Name
                    if (Test-Path $destMem) {
                        Get-Content $memFile.FullName -Raw | Add-Content $destMem -NoNewline
                        Write-Host "[Appended] memory/$($memFile.Name)"
                    } else {
                        Move-Item $memFile.FullName $destMem
                        Write-Host "[Moved]    memory/$($memFile.Name)"
                    }
                }
                Remove-Item $oldMemDir -Recurse -Force
            }
        }
        $changes++
    }

    # Step 2: Remove the now-empty orphan metadata directory
    if ($DryRun) {
        Write-Host "[Would remove] projects/$oldDirname"
    } else {
        Remove-Item $oldProjDir -Recurse -Force
        Write-Host "[Removed] projects/$oldDirname"
    }

    # Step 3: Update session JSON files (cwd field)
    $sessionsDir = Join-Path $ClaudeDir "sessions"
    if (Test-Path $sessionsDir) {
        foreach ($file in Get-ChildItem "$sessionsDir\*.json" -ErrorAction SilentlyContinue) {
            $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }
            if ($content.Contains("`"$oldPathJson`"")) {
                if ($DryRun) {
                    Write-Host "[Would update] sessions/$($file.Name)"
                } else {
                    $content = $content.Replace("`"$oldPathJson`"", "`"$newPathJson`"")
                    Set-Content $file.FullName $content -NoNewline
                    Write-Host "[Updated] sessions/$($file.Name)"
                }
                $changes++
            }
        }
    }

    # Step 4: Update history.jsonl
    $historyFile = Join-Path $ClaudeDir "history.jsonl"
    if (Test-Path $historyFile) {
        $content = Get-Content $historyFile -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Contains("`"$oldPathJson`"")) {
            if ($DryRun) {
                $count = ([regex]::Matches($content, [regex]::Escape("`"$oldPathJson`""))).Count
                Write-Host "[Would update] history.jsonl ($count occurrences)"
            } else {
                $content = $content.Replace("`"$oldPathJson`"", "`"$newPathJson`"")
                Set-Content $historyFile $content -NoNewline
                Write-Host "[Updated] history.jsonl"
            }
            $changes++
        }
    }

    Write-Host ""
    if ($DryRun) {
        Write-Host "Dry run complete. $changes change(s) would be made."
    } else {
        Write-Host "Done. $changes update(s) applied. Orphan metadata merged into projects/$newDirname."
    }
}

# --- Purge orphan ---

function Get-ProjectDescription {
    param([string]$ProjDir)

    $sessionCount = (Get-ChildItem "$ProjDir\*.jsonl" -ErrorAction SilentlyContinue | Measure-Object).Count
    $hasMemory = if (Test-Path (Join-Path $ProjDir "memory")) { "yes" } else { "no" }
    Write-Host "  Sessions: $sessionCount, Memory: $hasMemory"
}

function Remove-SingleOrphan {
    param([string]$Path)

    $dirname = ConvertTo-ClaudeDirname $Path
    $projDir = Join-Path $ProjectsDir $dirname
    $pathJson = $Path.Replace('\', '\\')

    if (-not (Test-Path $projDir)) {
        Write-Error "No metadata found for path: $Path`n  (expected directory: $projDir)"
        return $false
    }

    if (Test-Path $Path) {
        Write-Error "$Path still exists on disk - this is not an orphan"
        return $false
    }

    Write-Host "Orphan: $Path"
    Get-ProjectDescription $projDir

    if ($DryRun) {
        Write-Host "  [Would delete] projects/$dirname"

        # Check for session/history references
        $sessionsDir = Join-Path $ClaudeDir "sessions"
        if (Test-Path $sessionsDir) {
            foreach ($file in Get-ChildItem "$sessionsDir\*.json" -ErrorAction SilentlyContinue) {
                $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
                if ($content -and $content.Contains("`"$pathJson`"")) {
                    Write-Host "  [Would clean] sessions/$($file.Name)"
                }
            }
        }
        $historyFile = Join-Path $ClaudeDir "history.jsonl"
        if (Test-Path $historyFile) {
            $content = Get-Content $historyFile -Raw -ErrorAction SilentlyContinue
            if ($content -and $content.Contains("`"$pathJson`"")) {
                $count = ([regex]::Matches($content, [regex]::Escape("`"$pathJson`""))).Count
                Write-Host "  [Would clean] history.jsonl ($count lines)"
            }
        }
        return $true
    }

    # Confirmation
    if (-not $Yes) {
        $reply = Read-Host "  Delete this metadata permanently? [y/N]"
        if ($reply -notmatch '^[yY]') {
            Write-Host "  Skipped."
            return $true
        }
    }

    # Delete project metadata
    Remove-Item $projDir -Recurse -Force
    Write-Host "  [Deleted] projects/$dirname"

    # Clean references from session files
    $sessionsDir = Join-Path $ClaudeDir "sessions"
    if (Test-Path $sessionsDir) {
        foreach ($file in Get-ChildItem "$sessionsDir\*.json" -ErrorAction SilentlyContinue) {
            $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -and $content.Contains("`"$pathJson`"")) {
                Remove-Item $file.FullName
                Write-Host "  [Cleaned] sessions/$($file.Name)"
            }
        }
    }

    # Clean references from history.jsonl
    $historyFile = Join-Path $ClaudeDir "history.jsonl"
    if (Test-Path $historyFile) {
        $content = Get-Content $historyFile -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Contains("`"$pathJson`"")) {
            $lines = Get-Content $historyFile | Where-Object { -not $_.Contains("`"$pathJson`"") }
            Set-Content $historyFile ($lines -join "`n") -NoNewline
            Write-Host "  [Cleaned] history.jsonl"
        }
    }

    return $true
}

function Invoke-Purge {
    $purgeAll = ($OldPath -eq "--all")

    if ($purgeAll) {
        # Collect all orphans
        $orphans = @()
        foreach ($projDir in Get-ChildItem $ProjectsDir -Directory -ErrorAction SilentlyContinue) {
            $projectPath = Get-ProjectPath $projDir.FullName
            if (-not $projectPath) {
                $orphans += @{ Path = $null; DirName = $projDir.Name; ProjDir = $projDir.FullName }
            } elseif (-not (Test-Path $projectPath)) {
                $orphans += @{ Path = $projectPath; DirName = $projDir.Name; ProjDir = $projDir.FullName }
            }
        }

        if ($orphans.Count -eq 0) {
            Write-Host "No orphaned projects found."
            return
        }

        Write-Host "Found $($orphans.Count) orphaned project(s):"
        Write-Host ""

        if ($DryRun) {
            foreach ($orphan in $orphans) {
                if ($orphan.Path) {
                    Remove-SingleOrphan $orphan.Path | Out-Null
                } else {
                    Write-Host "[unknown] $($orphan.DirName) (could not determine original path)"
                    Get-ProjectDescription $orphan.ProjDir
                    Write-Host "  [Would delete] projects/$($orphan.DirName)"
                }
                Write-Host ""
            }
            Write-Host "Dry run complete."
            return
        }

        # Show summary and confirm
        foreach ($orphan in $orphans) {
            if ($orphan.Path) {
                Write-Host "  $($orphan.Path)"
            } else {
                Write-Host "  [unknown] $($orphan.DirName)"
            }
            Get-ProjectDescription $orphan.ProjDir
        }
        Write-Host ""

        if (-not $Yes) {
            $reply = Read-Host "Delete ALL orphaned project metadata permanently? [y/N]"
            if ($reply -notmatch '^[yY]') {
                Write-Host "Aborted."
                return
            }
        }

        Write-Host ""
        $savedYes = $Yes
        $script:Yes = $true
        foreach ($orphan in $orphans) {
            if ($orphan.Path) {
                Remove-SingleOrphan $orphan.Path | Out-Null
            } else {
                Remove-Item $orphan.ProjDir -Recurse -Force
                Write-Host "[Deleted] projects/$($orphan.DirName)"
            }
            Write-Host ""
        }
        $script:Yes = $savedYes
        Write-Host "Done. All orphaned project metadata removed."
    } else {
        if (-not $OldPath) {
            Write-Error "'purge' requires a path argument or --all"
            exit 1
        }
        $resolvedPath = [System.IO.Path]::GetFullPath($OldPath).TrimEnd('\', '/')
        Remove-SingleOrphan $resolvedPath | Out-Null
    }
}

# --- Main ---

if ($Command -eq "fix") {
    Invoke-Fix
} elseif ($Command -eq "purge") {
    Invoke-Purge
} elseif ($Command) {
    Write-Error "Unknown command: $Command"
    exit 1
} else {
    Show-Orphans
}
