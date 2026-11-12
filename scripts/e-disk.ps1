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
}

function Get-RemoteRoot {
  $p = "$($env:R2_E_PREFIX)".Trim("/")
  if ($p) { return "r2:$($env:R2_BUCKET)/$p" }
  return "r2:$($env:R2_BUCKET)"
}

function Invoke-RcloneRc {
  param([string[]]$RcArgs, [int]$TimeoutSec = 30)
  $exe = Get-RcloneExe
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $job = Start-Job -ScriptBlock {
      param($exe, $args, $addr)
      & $exe rc @args --rc-addr $addr --json 2>&1
    } -ArgumentList $exe, $RcArgs, $RcAddr
    $done = Wait-Job $job -Timeout $TimeoutSec
    if (-not $done) {
      Stop-Job $job -ErrorAction SilentlyContinue
      Remove-Job $job -Force -ErrorAction SilentlyContinue
      Write-Host ("e-disk: rc timed out after {0}s: {1}" -f $TimeoutSec, ($RcArgs -join " "))
      return @()
    }
    $out = Receive-Job $job
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    return @($out | Where-Object { [string]$_ -notmatch "NOTICE" })
  } finally {
    $ErrorActionPreference = $old
  }
}

function Invoke-Mount {
  Set-RcloneR2Env
  Install-WinFsp
  $exe = Get-RcloneExe

  if (Test-Path "${Letter}:\") {
    Write-Host "e-disk: ${Letter}: already mapped"
    return
  }

  New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
  if (Test-Path $LogPath) { Remove-Item $LogPath -Force -ErrorAction SilentlyContinue }

  # 0777 for files and dirs: without the execute bit Windows refuses to launch
  # .exe/.dll served by the mount ("Access is denied").
  $args = @(
    "mount", (Get-RemoteRoot), "${Letter}:",
    "--vfs-cache-mode", "full",
    "--cache-dir", $CacheDir,
    "--vfs-cache-max-size", "20G",
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
  $proc = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden -ArgumentList $args
  $up = $false
  for ($i = 0; $i -lt 240; $i++) {
    Start-Sleep -Milliseconds 250
    if (Test-Path "${Letter}:\") { $up = $true; break }
    if ($proc.HasExited) { break }
  }
  $sec = ((Get-Date) - $t0).TotalSeconds
  Write-Host ("e-disk: ${Letter}: visible={0} seconds={1:N2}" -f $up, $sec)
  if (-not $up) {
    if (Test-Path $LogPath) { Get-Content $LogPath -Tail 40 -ErrorAction SilentlyContinue | Out-Host }
    throw "e-disk: ${Letter}: did not mount"
  }
}

function Invoke-Save {
  Set-RcloneR2Env
  if (-not (Test-Path "${Letter}:\")) {
    Write-Host "e-disk: ${Letter}: not mounted, nothing to flush"
    return
  }

  Write-Host "e-disk: flushing pending writes"
  Invoke-RcloneRc @("vfs/forget") | Out-Null

  $t0 = Get-Date
  Invoke-RcloneRc @("mount/unmount", "mountPoint=${Letter}:") | Out-Null
  $gone = $false
  for ($i = 0; $i -lt 240; $i++) {
    Start-Sleep -Milliseconds 250
    if (-not (Test-Path "${Letter}:\")) { $gone = $true; break }
  }
  if (-not $gone) {
    Write-Host "e-disk: graceful unmount timed out, stopping process"
    Get-Process rclone -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 5
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & cmd.exe /c "rmdir ${Letter}:" 2>&1 | Out-Null
    $ErrorActionPreference = $old
    $gone = -not (Test-Path "${Letter}:\")
  }
  Write-Host ("e-disk: unmounted={0} seconds={1:N2}" -f $gone, ((Get-Date) - $t0).TotalSeconds)
  if (-not $gone) { throw "e-disk: ${Letter}: still mounted after flush" }
}

if ($Action -eq "mount") { Invoke-Mount } else { Invoke-Save }
