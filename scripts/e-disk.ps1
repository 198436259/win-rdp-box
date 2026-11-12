param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("mount", "save")]
  [string]$Action
)

$ErrorActionPreference = "Stop"
$Letter = "E"
$RcAddr = "127.0.0.1:5572"

function Get-WorkRoot {
  if (Test-Path "D:\") { return "D:\e-disk" }
  $root = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return (Join-Path $root "e-disk")
}

$Work = Get-WorkRoot
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$LogPath = Join-Path $Work "mount.log"
$CacheDir = Join-Path $Work "vfs-cache"
$ConfPath = Join-Path $Work "rclone.conf"
$BaselinePath = Join-Path $Work "boot-baseline.json"
$TaskName = "FlexPCRcloneMountE"

function Save-BootBaseline {
  if (Test-Path $BaselinePath) { return }
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
  $obj | ConvertTo-Json -Depth 4 | Set-Content -Path $BaselinePath -Encoding UTF8
  Write-Host ("e-disk: captured boot baseline pf={0} pfx86={1} pd={2}" -f $pf.Count, $pfx86.Count, $pd.Count)
}

function Get-RcloneExe {
  $dir = Join-Path $Work "rclone"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $exe = Get-ChildItem $dir -Recurse -Filter rclone.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
  if ($exe) { return $exe }
  $zip = Join-Path $dir "rclone.zip"
  curl.exe -fsSL -o $zip "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
  Expand-Archive $zip $dir -Force
  return (Get-ChildItem $dir -Recurse -Filter rclone.exe | Select-Object -First 1 -ExpandProperty FullName)
}

function Install-WinFsp {
  $svc = Get-Service -Name WinFsp -ErrorAction SilentlyContinue
  if ($svc) {
    Write-Host "e-disk: WinFsp present"
    return
  }
  $msi = Join-Path $Work "winfsp.msi"
  Write-Host "e-disk: installing WinFsp"
  curl.exe -fsSL -o $msi "https://github.com/winfsp/winfsp/releases/download/v2.0/winfsp-2.0.23075.msi"
  $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "WinFsp install exit=$($p.ExitCode)" }
}

function Set-RcloneR2Env {
  if (-not $env:R2_ACCESS_KEY_ID) { throw "R2_ACCESS_KEY_ID missing" }
  if (-not $env:R2_SECRET_ACCESS_KEY) { throw "R2_SECRET_ACCESS_KEY missing" }
  if (-not $env:R2_BUCKET) { throw "R2_BUCKET missing" }
  if (-not $env:R2_ENDPOINT) { throw "R2_ENDPOINT missing" }
  $env:RCLONE_CONFIG_R2_TYPE = "s3"
  $env:RCLONE_CONFIG_R2_PROVIDER = "Cloudflare"
  $env:RCLONE_CONFIG_R2_ACCESS_KEY_ID = $env:R2_ACCESS_KEY_ID
  $env:RCLONE_CONFIG_R2_SECRET_ACCESS_KEY = $env:R2_SECRET_ACCESS_KEY
  $env:RCLONE_CONFIG_R2_ENDPOINT = $env:R2_ENDPOINT
  $env:RCLONE_CONFIG_R2_REGION = "auto"
  $env:RCLONE_CONFIG_R2_NO_CHECK_BUCKET = "true"

  $confText = @(
    "[r2]",
    "type = s3",
    "provider = Cloudflare",
    "access_key_id = $($env:R2_ACCESS_KEY_ID)",
    "secret_access_key = $($env:R2_SECRET_ACCESS_KEY)",
    "endpoint = $($env:R2_ENDPOINT)",
    "region = auto",
    "no_check_bucket = true"
  ) -join "`r`n"
  [IO.File]::WriteAllText($ConfPath, $confText + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
  & icacls.exe $ConfPath /inheritance:r /grant:r "SYSTEM:(F)" "Administrators:(F)" "${env:USERNAME}:(F)" 2>$null | Out-Null
}

function Get-RemoteRoot {
  $p = "$($env:R2_E_PREFIX)".Trim("/")
  if ($p) { return "r2:$($env:R2_BUCKET)/$p" }
  return "r2:$($env:R2_BUCKET)"
}

function Invoke-RcloneRc {
  # Direct call: vfs/stats and vfs/forget return immediately.
  param([string[]]$RcArgs)
  $exe = Get-RcloneExe
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    # rc prints JSON by default; --json means INPUT json and errors if bare.
    $out = & $exe rc @RcArgs --rc-addr $RcAddr 2>&1
    return @($out | Where-Object { [string]$_ -notmatch "NOTICE" })
  } finally {
    $ErrorActionPreference = $old
  }
}

function Invoke-RcloneRcWithTimeout {
  # mount/unmount can block on Windows; give it a hard ceiling in a child process.
  param([string[]]$RcArgs, [int]$TimeoutSec = 60)
  $exe = Get-RcloneExe
  $outFile = Join-Path $Work "rc-out.txt"
  if (Test-Path $outFile) { Remove-Item $outFile -Force -ErrorAction SilentlyContinue }
  $argLine = (@("rc") + $RcArgs + @("--rc-addr", $RcAddr)) -join " "
  $p = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
  $done = $p.WaitForExit($TimeoutSec * 1000)
  if (-not $done) {
    try { $p.Kill() } catch {}
    Write-Host ("e-disk: rc timed out after {0}s: {1}" -f $TimeoutSec, ($RcArgs -join " "))
    return @()
  }
  if (Test-Path $outFile) {
    return @(Get-Content $outFile -Raw -ErrorAction SilentlyContinue)
  }
  return @()
}

function Invoke-Mount {
  Set-RcloneR2Env
  Install-WinFsp
  Save-BootBaseline
  $exe = Get-RcloneExe

  if (Test-Path "${Letter}:\") {
    Write-Host "e-disk: ${Letter}: already mapped"
    return
  }

  New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
  if (Test-Path $LogPath) { Remove-Item $LogPath -Force -ErrorAction SilentlyContinue }

  # 0777 for files and dirs: without the execute bit Windows refuses to launch
  # .exe/.dll served by the mount ("Access is denied").
  # s3-chunk-size 64M + concurrency 16 + multi-thread-streams 16 restore full R2 bandwidth (~55-85 MB/s)
  # and cut Class A PUT requests by 12.6x compared to default 5MiB chunks.
  $args = @(
    "mount", (Get-RemoteRoot), "${Letter}:",
    "--config", $ConfPath,
    "--vfs-cache-mode", "full",
    "--cache-dir", $CacheDir,
    "--vfs-cache-max-size", "40G",
    "--s3-chunk-size", "64M",
    "--s3-upload-concurrency", "16",
    "--multi-thread-streams", "16",
    "--vfs-read-chunk-size", "32M",
    "--links",
    "--dir-cache-time", "10s",
    "--transfers", "16",
    "--file-perms", "0777",
    "--dir-perms", "0777",
    "--rc", "--rc-addr", $RcAddr,
    "--log-file", $LogPath,
    "--log-level", "INFO"
  )
  $t0 = Get-Date
  $up = $false
  $mode = "system-task"

  # Mounting as NT AUTHORITY\SYSTEM places E: in \GLOBAL??\E: so both Session 0
  # (GitHub Actions runner steps) and Session 2 (interactive RDP user desktop)
  # see the exact same E: drive letter.
  try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $quotedArgs = ($args | ForEach-Object { if ($_ -match "\s") { "`"$_`"" } else { $_ } }) -join " "
    $action = New-ScheduledTaskAction -Execute $exe -Argument $quotedArgs
    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    for ($i = 0; $i -lt 32; $i++) {
      Start-Sleep -Milliseconds 250
      if (Test-Path "${Letter}:\") { $up = $true; break }
    }
  } catch {
    Write-Host "e-disk: system task mount attempt failed: $_"
  }

  if (-not $up) {
    $mode = "process-fallback"
    Get-Process rclone -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden -ArgumentList $args
    for ($i = 0; $i -lt 240; $i++) {
      Start-Sleep -Milliseconds 250
      if (Test-Path "${Letter}:\") { $up = $true; break }
      if ($proc.HasExited) { break }
    }
  }

  $sec = ((Get-Date) - $t0).TotalSeconds
  Write-Host ("e-disk: ${Letter}: visible={0} mode={1} seconds={2:N2}" -f $up, $mode, $sec)
  if (-not $up) {
    if (Test-Path $LogPath) { Get-Content $LogPath -Tail 40 -ErrorAction SilentlyContinue | Out-Host }
    throw "e-disk: ${Letter}: did not mount"
  }
}

function Wait-VfsDrained {
  param([int]$TimeoutSec = 2400)
  $t0 = Get-Date
  $lastLog = -1
  while ($true) {
    $json = (Invoke-RcloneRc -RcArgs @("vfs/stats")) -join ""
    $pending = -1
    $inflight = -1
    if ($json -match '"uploadsQueued"\s*:\s*(\d+)') { $pending = [int]$Matches[1] }
    if ($json -match '"uploadsInProgress"\s*:\s*(\d+)') { $inflight = [int]$Matches[1] }
    if ($pending -eq 0 -and $inflight -eq 0) { return $true }
    if ($pending -lt 0 -and $inflight -lt 0) {
      $head = if ($json.Length -gt 300) { $json.Substring(0, 300) } else { $json }
      Write-Host ("e-disk: vfs/stats unreadable, cannot confirm drain: " + $head)
      return $false
    }
    $el = [int]((Get-Date) - $t0).TotalSeconds
    if ($el -gt $TimeoutSec) {
      Write-Host ("e-disk: drain timeout pending={0} inflight={1} elapsed={2}s" -f $pending, $inflight, $el)
      return $false
    }
    if ([Math]::Floor($el / 15) -ne $lastLog) {
      $lastLog = [Math]::Floor($el / 15)
      Write-Host ("e-disk: draining pending={0} inflight={1} elapsed={2}s" -f $pending, $inflight, $el)
    }
    Start-Sleep -Seconds 2
  }
}

function Invoke-Save {
  Set-RcloneR2Env
  if (-not (Test-Path "${Letter}:\")) {
    Write-Host "e-disk: ${Letter}: not mounted, nothing to flush"
    return
  }

  Write-Host "e-disk: waiting for pending uploads to finish"
  $t0 = Get-Date
  $drained = Wait-VfsDrained -TimeoutSec 2400
  Write-Host ("e-disk: drained={0} seconds={1:N1}" -f $drained, ((Get-Date) - $t0).TotalSeconds)
  if (-not $drained) {
    # Killing rclone here loses pending writes; fail loudly instead.
    throw "e-disk: uploads did not finish, refusing to unmount"
  }

  # rc mount/unmount never releases a WinFsp drive in our tests; killing the
  # process is safe once every upload has drained to R2.
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Get-Process rclone -ErrorAction SilentlyContinue | Stop-Process -Force
  $gone = $false
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if (-not (Test-Path "${Letter}:\")) { $gone = $true; break }
  }
  if (-not $gone) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & cmd.exe /c "rmdir ${Letter}:" 2>&1 | Out-Null
    $ErrorActionPreference = $old
    Start-Sleep -Seconds 2
    $gone = -not (Test-Path "${Letter}:\")
  }
  Write-Host ("e-disk: unmounted={0} seconds={1:N2}" -f $gone, ((Get-Date) - $t0).TotalSeconds)
  if (-not $gone) { throw "e-disk: ${Letter}: still mounted after flush" }
}

if ($Action -eq "mount") { Invoke-Mount } else { Invoke-Save }
