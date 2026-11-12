param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("save", "restore")]
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
  "Common Files", "Desktop.ini"
)

$Roots = @(
  @{ Path = "C:\Program Files"; Remote = "ProgramFiles" },
  @{ Path = "C:\Program Files (x86)"; Remote = "ProgramFilesX86" }
)

function Get-RcloneExe {
  $dir = if (Test-Path "D:\") { "D:\e-disk\rclone" } else { Join-Path $env:TEMP "e-disk\rclone" }
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $exe = Get-ChildItem $dir -Recurse -Filter rclone.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
  if ($exe) { return $exe }
  $zip = Join-Path $dir "rclone.zip"
  curl.exe -fsSL -o $zip "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
  Expand-Archive $zip $dir -Force
  return (Get-ChildItem $dir -Recurse -Filter rclone.exe | Select-Object -First 1 -ExpandProperty FullName)
}

function Get-RemoteRoot {
  $p = "$($env:R2_E_PREFIX)".Trim("/")
  if ($p) { return "r2:$($env:R2_BUCKET)/$p" }
  return "r2:$($env:R2_BUCKET)"
}

function Set-RcloneR2Env {
  if (-not $env:R2_BUCKET) { throw "R2_BUCKET missing" }
  $env:RCLONE_CONFIG_R2_TYPE = "s3"
  $env:RCLONE_CONFIG_R2_PROVIDER = "Cloudflare"
  $env:RCLONE_CONFIG_R2_ACCESS_KEY_ID = $env:R2_ACCESS_KEY_ID
  $env:RCLONE_CONFIG_R2_SECRET_ACCESS_KEY = $env:R2_SECRET_ACCESS_KEY
  $env:RCLONE_CONFIG_R2_ENDPOINT = $env:R2_ENDPOINT
  $env:RCLONE_CONFIG_R2_REGION = "auto"
  $env:RCLONE_CONFIG_R2_NO_CHECK_BUCKET = "true"
}

function Invoke-Rclone {
  param([string[]]$RcloneArgs)
  $exe = Get-RcloneExe
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out = & $exe @RcloneArgs 2>&1
    return @($out | Where-Object { [string]$_ -notmatch "NOTICE" })
  } finally {
    $ErrorActionPreference = $old
  }
}

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

function Invoke-Save {
  Set-RcloneR2Env
  if (-not (Test-Path "${Letter}:\")) { throw "apps: ${Letter}: not mounted" }

  $entries = @(Read-Manifest)
  $byPath = @{}
  foreach ($e in $entries) { if ($e.localPath) { $byPath[$e.localPath] = $e } }

  foreach ($root in $Roots) {
    if (-not (Test-Path $root.Path)) { continue }
    $children = Get-ChildItem $root.Path -Directory -Force -ErrorAction SilentlyContinue
    foreach ($c in $children) {
      if ($SkipNames -contains $c.Name) { continue }
      if (Test-IsJunction $c.FullName) { continue }

      $remote = (Get-RemoteRoot) + "/$($root.Remote)/$($c.Name)"
      $t0 = Get-Date
      $out = Invoke-Rclone @("copy", $c.FullName, $remote, "--transfers", "16", "--checkers", "32", "--s3-chunk-size", "64M")
      $code = $LASTEXITCODE
      $sec = ((Get-Date) - $t0).TotalSeconds
      if ($code -ne 0) {
        Write-Host ("apps: upload failed name={0} exit={1}" -f $c.Name, $code)
        continue
      }

      $localFiles = @(Get-ChildItem $c.FullName -Recurse -File -ErrorAction SilentlyContinue)
      $localBytes = [long]0
      foreach ($f in $localFiles) { $localBytes += $f.Length }
      $remoteCount = @(Invoke-Rclone @("lsf", $remote, "--recursive") | Where-Object { $_ -notmatch "NOTICE" }).Count
      Write-Host ("apps: uploaded name={0} files={1} bytes={2} remote={3} seconds={4:N1}" -f $c.Name, $localFiles.Count, $localBytes, $remoteCount, $sec)
      if ($remoteCount -lt $localFiles.Count) {
        Write-Host ("apps: remote count short for {0}, keeping local copy" -f $c.Name)
        continue
      }

      $target = Join-Path ("${Letter}:\" + $root.Remote) $c.Name
      if (-not (Test-Path $target)) {
        Write-Host ("apps: remote target not visible {0}" -f $target)
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

function Invoke-Restore {
  Set-RcloneR2Env
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

if ($Action -eq "save") { Invoke-Save } else { Invoke-Restore }
