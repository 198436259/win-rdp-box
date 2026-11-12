param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("save", "restore")]
  [string]$Action,
  [string]$OutZip = "",
  [string]$TargetDir = ""
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$WorkRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$Work = Join-Path $WorkRoot "c-image"
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$Stage = Join-Path $Work "stage"
$Zip = Join-Path $Work "c-snapshot.zip"
$FilesRoot = Join-Path $Stage "system\files"
$RegDir = Join-Path $Stage "system\registry"
$LoginRoot = Join-Path $Stage "logins"

$SkipEnvNames = @(
  "GITHUB_TOKEN", "GITHUB_PATH", "GITHUB_ENV", "GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY",
  "ACTIONS_RUNTIME_TOKEN", "ACTIONS_ID_TOKEN_REQUEST_TOKEN", "ACTIONS_ID_TOKEN_REQUEST_URL",
  "NGROK_AUTHTOKEN"
)

$FileTrees = @(
  "Desktop",
  "Documents",
  "Downloads",
  "Pictures",
  ".ssh",
  ".claude",
  ".codex",
  ".gitconfig",
  "AppData\Roaming\Claude",
  "AppData\Roaming\Anthropic",
  "AppData\Roaming\Codex",
  "AppData\Roaming\WeType",
  "AppData\Roaming\Tencent\WeType",
  "AppData\Roaming\RustDesk",
  "AppData\Roaming\UGit",
  "AppData\Roaming\Microsoft\Windows\Start Menu\Programs",
  "AppData\Local\Claude",
  "AppData\Local\AnthropicClaude",
  "AppData\Local\Anthropic",
  "AppData\Local\Codex",
  "AppData\Local\RustDesk",
  "AppData\Local\UGit",
  "AppData\Local\Tencent\WeType",
  "AppData\Local\Programs"
)

# Program Files is handled by apps.ps1 (junction to R2 persists installed apps).
# Only ProgramData is copied here.
$MachineTrees = @(
  "C:\ProgramData"
)

$MachineXd = @(
  "Package Cache", "WER", "Caches", "Windows Defender", "Defender",
  "USOShared", "USOPrivate", "Downloaded Program Files",
  "WindowsApps", "SquirrelTemp", "CrashDumps"
)
$MachineXf = @("*.etl", "*.dmp")

$LoginTrees = @(
  "AppData\Roaming\Claude",
  "AppData\Roaming\Anthropic",
  "AppData\Local\Claude",
  "AppData\Local\AnthropicClaude",
  "AppData\Local\Anthropic",
  "AppData\Roaming\Codex",
  "AppData\Local\Codex",
  ".claude",
  ".codex"
)

$HkcuKeys = @(
  "HKCU\Environment",
  "HKCU\Software\Anthropic",
  "HKCU\Software\Claude",
  "HKCU\Software\Codex",
  "HKCU\Software\Tencent",
  "HKCU\Software\RustDesk",
  "HKCU\Software\UGit",
  "HKCU\Software\Microsoft\Windows\CurrentVersion\Run",
  "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
)

$HklmKeys = @(
  "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
  "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
  "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
)

$RoboXd = @(
  "Cache", "Code Cache", "GPUCache", "Crashpad", "Temp", "Temporary Internet Files",
  "CacheStorage", "DawnCache", "GrShaderCache", "ShaderCache", "CachedData",
  "win-rdp-src"
)
$RoboXf = @("*.lock", "*.tmp", "env.json", "save-image.log")

function Get-SnapshotRepo {
  if ($env:SNAPSHOT_REPO) { return $env:SNAPSHOT_REPO }
  return $env:GITHUB_REPOSITORY
}

function Get-GhHeaders {
  if (-not $env:GITHUB_TOKEN) { throw "GITHUB_TOKEN missing" }
  return @{
    Authorization          = "Bearer $($env:GITHUB_TOKEN)"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
  }
}

function Invoke-CopyTree {
  param([string]$Src, [string]$Dst, [string[]]$ExtraXd = @(), [string[]]$ExtraXf = @())
  if (-not (Test-Path $Src)) { return 0 }
  $item = Get-Item $Src -Force
  if (-not $item.PSIsContainer) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Dst) | Out-Null
    Copy-Item $item.FullName $Dst -Force
    return 1
  }
  New-Item -ItemType Directory -Force -Path $Dst | Out-Null
  $xd = @($RoboXd) + @($ExtraXd)
  $xf = @($RoboXf) + @($ExtraXf)
  $args = @($Src, $Dst, "/E", "/XJ", "/R:1", "/W:1", "/NFL", "/NDL", "/NJH", "/NJS", "/NP")
  if ($xd.Count) { $args += @("/XD") + $xd }
  if ($xf.Count) { $args += @("/XF") + $xf }
  & robocopy @args | Out-Null
  return 1
}

function Ensure-Release {
  $repo = Get-SnapshotRepo
  $headers = Get-GhHeaders
  try {
    return Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$repo/releases/tags/c-image"
  } catch {
    $body = @{
      tag_name         = "c-image"
      name             = "C-disk user-state snapshot"
      body             = "User-state delta (files + HKCU + user env + Claude/Codex login dirs). Not a full disk image. D: is not saved."
      draft            = $false
      prerelease       = $false
    } | ConvertTo-Json
    return Invoke-RestMethod -Method POST -Headers $headers -ContentType "application/json" -Uri "https://api.github.com/repos/$repo/releases" -Body $body
  }
}

function Save-UserVariables {
  $out = Join-Path $Stage "system\variables.json"
  $items = @()
  Get-ItemProperty -Path "HKCU:\Environment" -ErrorAction SilentlyContinue | ForEach-Object {
    $_.PSObject.Properties | Where-Object {
      $_.Name -notmatch "^PS" -and $SkipEnvNames -notcontains $_.Name
    } | ForEach-Object {
      $items += [pscustomobject]@{ Name = $_.Name; Value = [string]$_.Value }
    }
  }
  $items | ConvertTo-Json -Depth 4 | Set-Content -Path $out -Encoding UTF8
  return $items.Count
}

function Get-LoginApps {
  $apps = @()
  $claudeHit = $false
  foreach ($rel in @(
      "AppData\Roaming\Claude",
      "AppData\Local\AnthropicClaude",
      "AppData\Local\Claude",
      "AppData\Local\Packages"
    )) {
    $p = Join-Path $env:USERPROFILE $rel
    if ($rel -eq "AppData\Local\Packages") {
      Get-ChildItem $p -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "Claude*" } | ForEach-Object { $claudeHit = $true }
    } elseif (Test-Path $p) { $claudeHit = $true }
  }
  if ($claudeHit) {
    $apps += [pscustomobject]@{ app = "claude"; accountEmail = ""; size = 0 }
  }
  foreach ($rel in @("AppData\Roaming\Codex", "AppData\Local\Codex", ".codex")) {
    if (Test-Path (Join-Path $env:USERPROFILE $rel)) {
      $apps += [pscustomobject]@{ app = "codex"; accountEmail = ""; size = 0 }
      break
    }
  }
  return @($apps)
}

function Save-Image {
  if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $FilesRoot, $RegDir, $LoginRoot | Out-Null

  $copied = 0
  foreach ($rel in $FileTrees) {
    $src = Join-Path $env:USERPROFILE $rel
    $copied += Invoke-CopyTree $src (Join-Path $FilesRoot $rel)
  }

  foreach ($abs in $MachineTrees) {
    if (-not (Test-Path $abs)) { continue }
    $leaf = Split-Path $abs -Leaf
    $dst = Join-Path $Stage ("machine\" + $leaf)
    $t0 = Get-Date
    Invoke-CopyTree $abs $dst $MachineXd $MachineXf | Out-Null
    $files = 0; $bytes = [int64]0
    Get-ChildItem $dst -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $files++; $bytes += $_.Length }
    Write-Host ("machine {0} files={1} bytes={2} seconds={3:N1}" -f $leaf, $files, $bytes, ((Get-Date) - $t0).TotalSeconds)
  }

  Get-ChildItem (Join-Path $env:USERPROFILE "AppData\Local\Packages") -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "Claude*" } |
    ForEach-Object {
      $dst = Join-Path $FilesRoot "AppData\Local\Packages\$($_.Name)"
      $copied += Invoke-CopyTree $_.FullName $dst
      $loginDst = Join-Path $LoginRoot "claude\Packages\$($_.Name)"
      Invoke-CopyTree $_.FullName $loginDst | Out-Null
    }

  foreach ($rel in $LoginTrees) {
    $src = Join-Path $env:USERPROFILE $rel
    $dst = Join-Path $LoginRoot ("claude\" + ($rel -replace "[\\/]", "_"))
    if ($rel -match "Codex|codex") {
      $dst = Join-Path $LoginRoot ("codex\" + ($rel -replace "[\\/]", "_"))
    }
    Invoke-CopyTree $src $dst | Out-Null
  }

  $i = 0
  $keyCount = 0
  foreach ($k in $HkcuKeys) {
    $i++
    $out = Join-Path $RegDir ("hkcu-{0:D2}.reg" -f $i)
    & reg.exe export $k $out /y 2>$null | Out-Null
    if (Test-Path $out) { $keyCount++ }
  }
  $hklmDir = Join-Path $RegDir "HKLM"
  New-Item -ItemType Directory -Force -Path $hklmDir | Out-Null
  $j = 0
  foreach ($k in $HklmKeys) {
    $j++
    $out = Join-Path $hklmDir ("hklm-{0:D2}.reg" -f $j)
    & reg.exe export $k $out /y 2>$null | Out-Null
    if (Test-Path $out) { $keyCount++ }
  }

  $varCount = Save-UserVariables

  $fileCount = 0
  $byteCount = [int64]0
  Get-ChildItem $Stage -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $fileCount++
    $byteCount += $_.Length
  }
  $logins = @(Get-LoginApps)
  if ($TargetDir) {
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    $manifestEarly = [pscustomobject]@{
      kind      = "c-delta"
      savedAt   = [DateTime]::UtcNow.ToString("o")
      user      = $env:USERNAME
      computer  = $env:COMPUTERNAME
      system    = [pscustomobject]@{
        files     = $fileCount
        bytes     = $byteCount
        keys      = $keyCount
        variables = $varCount
        trees     = $copied
      }
      logins    = $logins
      note      = "User-state delta on persist volume. Not a full C: image."
    }
    $manifestEarly | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $Stage "manifest.json") -Encoding UTF8
    & robocopy $Stage $TargetDir /MIR /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    $loginHint = if ($logins.Count) { " logins=" + (($logins | ForEach-Object { $_.app }) -join ",") } else { "" }
    Write-Host ("c-delta dir={0} files={1} keys={2} variables={3}{4}" -f $TargetDir, $fileCount, $keyCount, $varCount, $loginHint)
    return
  }
  $manifest = [pscustomobject]@{
    kind      = "c-delta"
    savedAt   = [DateTime]::UtcNow.ToString("o")
    user      = $env:USERNAME
    computer  = $env:COMPUTERNAME
    system    = [pscustomobject]@{
      files     = $fileCount
      bytes     = $byteCount
      keys      = $keyCount
      variables = $varCount
      trees     = $copied
    }
    logins    = $logins
    note      = "User-state only. Not a full C: image. Temp disk is not saved."
  }
  $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $Stage "manifest.json") -Encoding UTF8

  if (Test-Path $Zip) { Remove-Item $Zip -Force }
  $tarOk = $false
  try {
    Push-Location $Stage
    & tar.exe -a -c -f $Zip * 2>$null
    Pop-Location
    if ((Test-Path $Zip) -and ((Get-Item $Zip).Length -gt 64)) { $tarOk = $true }
  } catch {
    if ((Get-Location).Path -eq $Stage) { Pop-Location }
  }
  if (-not $tarOk) {
    Compress-Archive -Path (Join-Path $Stage "*") -DestinationPath $Zip -Force
  }
  $len = (Get-Item $Zip).Length
  $loginHint = if ($logins.Count) { " logins=" + (($logins | ForEach-Object { $_.app }) -join ",") } else { "" }
  Write-Host ("snapshot zip bytes={0} files={1} keys={2} variables={3}{4}" -f $len, $fileCount, $keyCount, $varCount, $loginHint)

  if ($OutZip) {
    New-Item -ItemType Directory -Force -Path (Split-Path $OutZip) | Out-Null
    Copy-Item $Zip $OutZip -Force
    Write-Host "wrote local zip $OutZip bytes=$len"
    return
  }

  $rel = Ensure-Release
  $headers = Get-GhHeaders
  $existing = @($rel.assets | Where-Object { $_.name -eq "c-snapshot.zip" })
  foreach ($a in $existing) {
    Invoke-RestMethod -Method DELETE -Headers $headers -Uri $a.url
  }
  $uploadUrl = ($rel.upload_url -split "\{")[0] + "?name=c-snapshot.zip"
  $code = & curl.exe -sS -o "$Work\upload-resp.txt" -w "%{http_code}" -X POST `
    -H "Authorization: Bearer $($env:GITHUB_TOKEN)" `
    -H "Accept: application/vnd.github+json" `
    -H "Content-Type: application/zip" `
    -H "X-GitHub-Api-Version: 2022-11-28" `
    --data-binary "@$Zip" `
    $uploadUrl
  Write-Host "upload http=$code"
  if ($code -ne "201" -and $code -ne "200") {
    Get-Content "$Work\upload-resp.txt" -ErrorAction SilentlyContinue | Select-Object -First 20
    throw "upload failed"
  }
  Write-Host "uploaded c-snapshot.zip to release c-image"
}

function Restore-Image {
  $fromDir = $false
  if ($TargetDir -and (Test-Path (Join-Path $TargetDir "manifest.json"))) {
    Write-Host "restore from $TargetDir"
    $Stage = $TargetDir
    $FilesRoot = Join-Path $Stage "system\files"
    $RegDir = Join-Path $Stage "system\registry"
    $LoginRoot = Join-Path $Stage "logins"
    $fromDir = $true
  }
  if (-not $fromDir) {
    if (-not $env:GITHUB_TOKEN) { Write-Host "no token, skip restore"; return }
    $headers = Get-GhHeaders
    try {
      $rel = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$(Get-SnapshotRepo)/releases/tags/c-image"
    } catch {
      Write-Host "no c-image release yet, skip restore"
      return
    }
    $asset = @($rel.assets | Where-Object { $_.name -eq "c-snapshot.zip" }) | Select-Object -First 1
    if (-not $asset) { Write-Host "no c-snapshot.zip asset, skip restore"; return }
    Write-Host "downloading snapshot id=$($asset.id) size=$($asset.size)"
    & curl.exe -fsSL -L -H "Authorization: Bearer $($env:GITHUB_TOKEN)" -H "Accept: application/octet-stream" -o $Zip $asset.url
    if (-not (Test-Path $Zip) -or ((Get-Item $Zip).Length -lt 100)) { Write-Host "download failed"; return }
    if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Stage | Out-Null
    try {
      & tar.exe -a -x -f $Zip -C $Stage 2>$null
    } catch {}
    if (-not (Get-ChildItem $Stage -ErrorAction SilentlyContinue)) {
      Expand-Archive -Path $Zip -DestinationPath $Stage -Force
    }
  }

  $man = Join-Path $Stage "manifest.json"
  if (Test-Path $man) {
    Write-Host "manifest:"
    Get-Content $man -Raw
  }

  $legacy = -not (Test-Path $FilesRoot)
  if ($legacy) {
    Get-ChildItem $Stage -Force | Where-Object { $_.Name -notin @("registry", "system", "logins", "manifest.json") } | ForEach-Object {
      $dst = Join-Path $env:USERPROFILE $_.Name
      if ($_.PSIsContainer) {
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        & robocopy $_.FullName $dst /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
      } else {
        Copy-Item $_.FullName $dst -Force
      }
    }
    Get-ChildItem (Join-Path $Stage "registry") -Filter *.reg -ErrorAction SilentlyContinue | ForEach-Object {
      & reg.exe import $_.FullName 2>$null | Out-Null
    }
  } else {
    Get-ChildItem $FilesRoot -Force -ErrorAction SilentlyContinue | ForEach-Object {
      $dst = Join-Path $env:USERPROFILE $_.Name
      if ($_.PSIsContainer) {
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        & robocopy $_.FullName $dst /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
      } else {
        Copy-Item $_.FullName $dst -Force
      }
    }
    Get-ChildItem $RegDir -Filter *.reg -ErrorAction SilentlyContinue | ForEach-Object {
      & reg.exe import $_.FullName 2>$null | Out-Null
    }
    $hklmDir = Join-Path $RegDir "HKLM"
    if (Test-Path $hklmDir) {
      Get-ChildItem $hklmDir -Filter *.reg -ErrorAction SilentlyContinue | ForEach-Object {
        & reg.exe import $_.FullName 2>$null | Out-Null
      }
    }
    $machineRoot = Join-Path $Stage "machine"
    if (Test-Path $machineRoot) {
      Get-ChildItem $machineRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $dst = Join-Path "C:\" $_.Name
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        $t0 = Get-Date
        & robocopy $_.FullName $dst /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        Write-Host ("restore machine {0} seconds={1:N1}" -f $_.Name, ((Get-Date) - $t0).TotalSeconds)
      }
    }
    $varFile = Join-Path $Stage "system\variables.json"
    if (Test-Path $varFile) {
      $vars = Get-Content $varFile -Raw | ConvertFrom-Json
      foreach ($v in @($vars)) {
        if (-not $v.Name) { continue }
        if ($SkipEnvNames -contains $v.Name) { continue }
        if ($v.Name -match "^(GITHUB_|RUNNER_|ACTIONS_|AGENT_)") { continue }
        try {
          [System.Environment]::SetEnvironmentVariable([string]$v.Name, [string]$v.Value, "User")
        } catch {}
      }
    }
    if (Test-Path $LoginRoot) {
      $claudeFiles = Join-Path $Stage "system\files"
      foreach ($appDir in (Get-ChildItem $LoginRoot -Directory -ErrorAction SilentlyContinue)) {
        Get-ChildItem $appDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
          $name = $_.Name
          $mapped = $name -replace "_", "\"
          if ($mapped -match "AppData|^\.claude|^\.codex") {
            $dst = Join-Path $env:USERPROFILE $mapped
            New-Item -ItemType Directory -Force -Path $dst | Out-Null
            & robocopy $_.FullName $dst /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
          }
        }
      }
      if (Test-Path (Join-Path $LoginRoot "claude\Packages")) {
        Get-ChildItem (Join-Path $LoginRoot "claude\Packages") -Directory -ErrorAction SilentlyContinue | ForEach-Object {
          $dst = Join-Path $env:USERPROFILE "AppData\Local\Packages\$($_.Name)"
          New-Item -ItemType Directory -Force -Path $dst | Out-Null
          & robocopy $_.FullName $dst /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        }
      }
      $null = $claudeFiles
    }
  }
  Write-Host "restore done"
}

if ($Action -eq "save") { Save-Image } else { Restore-Image }
