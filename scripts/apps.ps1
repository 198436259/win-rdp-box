param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("save", "restore", "link")]
  [string]$Action
)

$ErrorActionPreference = "Stop"
$Letter = "E"
$ManifestRel = "CloudVM-C\apps-manifest.json"

# Never move these: they are OS components, and a broken junction here makes the
# machine unbootable or breaks Windows Update / Defender / Store.
$SkipNames = @(
  "WindowsApps", "Windows Defender", "Windows Defender Advanced Threat Protection",
  "Windows NT", "Windows Mail", "Windows Media Player", "Windows Multimedia Platform",
  "Windows Photo Viewer", "Windows Portable Devices", "Windows Security",
  "Windows Sidebar", "WindowsPowerShell", "ModifiableWindowsApps",
  "Internet Explorer", "Uninstall Information", "Reference Assemblies",
  "MSBuild", "dotnet", "Microsoft", "Microsoft Update Health Tools",
  "Common Files", "Desktop.ini", "WinFsp"
)

$Roots = @(
  @{ Path = "C:\Program Files"; Remote = "ProgramFiles" },
  @{ Path = "C:\Program Files (x86)"; Remote = "ProgramFilesX86" }
)

function Get-ManifestPath {
  return (Join-Path "${Letter}:\" $ManifestRel)
}

function Read-Manifest {
  $p = Get-ManifestPath
  if (-not (Test-Path $p)) { return @() }
  try {
    $j = Get-Content $p -Raw | ConvertFrom-Json
    return @($j.entries)
  } catch {
    Write-Host "apps: manifest unreadable, treating as empty"
    return @()
  }
}

function Write-Manifest([object[]]$Entries) {
  $p = Get-ManifestPath
  $dir = Split-Path $p
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $payload = [pscustomobject]@{
    savedAt = [DateTime]::UtcNow.ToString("o")
    entries = @($Entries)
  }
  $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $p -Encoding UTF8
  Write-Host ("apps: manifest entries={0}" -f @($Entries).Count)
}

function Remove-LocalDir([string]$path) {
  try {
    Remove-Item $path -Recurse -Force -ErrorAction Stop
    return $true
  } catch {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & takeown.exe /F $path /R /D Y 2>&1 | Out-Null
    & icacls.exe $path /grant "${env:USERNAME}:(OI)(CI)F" /T 2>&1 | Out-Null
    $ErrorActionPreference = $old
    try {
      Remove-Item $path -Recurse -Force -ErrorAction Stop
      return $true
    } catch {
      Write-Host ("apps: could not remove {0}: {1}" -f $path, $_)
      return $false
    }
  }
}

function New-Junction([string]$path, [string]$target) {
  if (Test-Path $target) {
    New-Item -ItemType Junction -Path $path -Target $target -Force | Out-Null
    return $true
  }
  Write-Host "apps: target missing $target"
  return $false
}

function Test-IsJunction([string]$path) {
  $i = Get-Item $path -Force -ErrorAction SilentlyContinue
  if (-not $i) { return $false }
  return ($i.LinkType -eq "Junction" -or $i.LinkType -eq "SymbolicLink")
}

function Get-WorkRoot {
  if ((Test-Path "D:\") -and ((Get-PSDrive D).Free -gt 20GB)) { return "D:\e-disk" }
  $root = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
  return (Join-Path $root "e-disk")
}

function Ensure-BootBaseline {
  $work = Get-WorkRoot
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $bp = Join-Path $work "boot-baseline.json"
  if (Test-Path $bp) {
    try { return (Get-Content $bp -Raw | ConvertFrom-Json) } catch {}
  }
  $pf = @()
  $pfx86 = @()
  $pd = @()
  if (Test-Path "C:\Program Files") {
    $pf = @(Get-ChildItem "C:\Program Files" -Directory -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.LinkType -ne "Junction" -and $_.LinkType -ne "SymbolicLink" } |
      Select-Object -ExpandProperty Name)
  }
  if (Test-Path "C:\Program Files (x86)") {
    $pfx86 = @(Get-ChildItem "C:\Program Files (x86)" -Directory -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.LinkType -ne "Junction" -and $_.LinkType -ne "SymbolicLink" } |
      Select-Object -ExpandProperty Name)
  }
  if (Test-Path "C:\ProgramData") {
    $pd = @(Get-ChildItem "C:\ProgramData" -Directory -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.LinkType -ne "Junction" -and $_.LinkType -ne "SymbolicLink" } |
      Select-Object -ExpandProperty Name)
  }
  $obj = [pscustomobject]@{
    capturedAt      = [DateTime]::UtcNow.ToString("o")
    ProgramFiles    = $pf
    ProgramFilesX86 = $pfx86
    ProgramData     = $pd
  }
  $obj | ConvertTo-Json -Depth 4 | Set-Content -Path $bp -Encoding UTF8
  return $obj
}

function Invoke-Save {
  if (-not (Test-Path "${Letter}:\")) { throw "apps: ${Letter}: not mounted" }

  $baseline = Ensure-BootBaseline
  $entries = @(Read-Manifest)
  $byPath = @{}
  foreach ($e in $entries) { if ($e.localPath) { $byPath[$e.localPath] = $e } }

  foreach ($root in $Roots) {
    if (-not (Test-Path $root.Path)) { continue }
    $baseList = if ($root.Remote -eq "ProgramFiles") { @($baseline.ProgramFiles) } else { @($baseline.ProgramFilesX86) }
    $children = Get-ChildItem $root.Path -Directory -Force -ErrorAction SilentlyContinue
    foreach ($c in $children) {
      if ($SkipNames -contains $c.Name) { continue }
      if (Test-IsJunction $c.FullName) { continue }
      if ($env:APPS_ONLY) {
        if ($c.Name -ne $env:APPS_ONLY) { continue }
      } else {
        if (($baseList -contains $c.Name) -and (-not $byPath.ContainsKey($c.FullName))) {
          continue
        }
      }

      $localFiles = @(Get-ChildItem $c.FullName -Recurse -File -ErrorAction SilentlyContinue)
      $localBytes = [long]0
      foreach ($f in $localFiles) { $localBytes += $f.Length }

      # Copy directly into E:\ProgramFiles\<App> on local VHDX (zero extra R2 Class A requests;
      # persisted and zstd-compressed automatically inside diff.vhdx.zst / base.vhdx.zst).
      $target = Join-Path ("${Letter}:\" + $root.Remote) $c.Name
      New-Item -ItemType Directory -Force -Path $target | Out-Null
      $t0 = Get-Date
      $old = $ErrorActionPreference
      $ErrorActionPreference = "Continue"
      & robocopy $c.FullName $target /MIR /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
      $rc = $LASTEXITCODE
      $ErrorActionPreference = $old
      $sec = ((Get-Date) - $t0).TotalSeconds
      if ($rc -ge 8) {
        Write-Host ("apps: robocopy failed name={0} exit={1}" -f $c.Name, $rc)
        continue
      }

      $dstFiles = @(Get-ChildItem $target -Recurse -File -ErrorAction SilentlyContinue)
      Write-Host ("apps: staged to E: name={0} files={1} bytes={2} dstFiles={3} seconds={4:N2}" -f $c.Name, $localFiles.Count, $localBytes, $dstFiles.Count, $sec)
      if ($dstFiles.Count -lt $localFiles.Count) {
        Write-Host ("apps: target count short for {0}, keeping local copy" -f $c.Name)
        continue
      }

      if (-not (Remove-LocalDir $c.FullName)) { continue }
      if (-not (New-Junction $c.FullName $target)) {
        Write-Host ("apps: junction failed for {0}" -f $c.Name)
        continue
      }
      Write-Host ("apps: junctioned {0} -> {1}" -f $c.FullName, $target)
      $byPath[$c.FullName] = [pscustomobject]@{
        localPath = $c.FullName
        target    = $target
        files     = $localFiles.Count
        bytes     = $localBytes
      }
    }
  }

  Write-Manifest @($byPath.Values)
}

function Invoke-Link {
  if (-not (Test-Path "${Letter}:\")) { throw "apps: ${Letter}: not mounted" }
  $name = $env:APPS_ONLY
  if (-not $name) { throw "apps: APPS_ONLY missing" }
  foreach ($root in $Roots) {
    $local = Join-Path $root.Path $name
    if (-not (Test-Path $local)) { continue }
    if (Test-IsJunction $local) { Write-Host "apps: already linked $local"; continue }
    $target = Join-Path ("${Letter}:\" + $root.Remote) $name
    if (-not (Test-Path $target)) { Write-Host "apps: target missing $target"; continue }
    if (-not (Remove-LocalDir $local)) { continue }
    if (New-Junction $local $target) {
      Write-Host ("apps: junctioned {0} -> {1}" -f $local, $target)
    }
  }
}

function Invoke-Restore {
  Ensure-BootBaseline | Out-Null
  if (-not (Test-Path "${Letter}:\")) { throw "apps: ${Letter}: not mounted" }

  $entries = @(Read-Manifest)
  if (-not $entries.Count) { Write-Host "apps: no manifest, nothing to restore"; return }

  $ok = 0; $fail = 0
  foreach ($e in $entries) {
    if (-not $e.localPath) { continue }
    $target = $e.target
    if (-not $target) { continue }
    if (Test-IsJunction $e.localPath) { $ok++; continue }
    if (Test-Path $e.localPath) {
      Write-Host ("apps: local dir still present, skipping junction {0}" -f $e.localPath)
      $fail++
      continue
    }
    $parent = Split-Path $e.localPath
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (New-Junction $e.localPath $target) {
      Write-Host ("apps: restored {0}" -f $e.localPath)
      $ok++
    } else {
      Write-Host ("apps: restore failed {0}" -f $e.localPath)
      $fail++
    }
  }
  Write-Host ("apps: restore ok={0} fail={1}" -f $ok, $fail)
}

if ($Action -eq "save") { Invoke-Save } elseif ($Action -eq "link") { Invoke-Link } else { Invoke-Restore }
