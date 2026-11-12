param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("mount", "save")]
  [string]$Action
)

$ErrorActionPreference = "Stop"
$Letter = "E"

function Get-WorkRoot {
  if ((Test-Path "D:\") -and ((Get-PSDrive D).Free -gt 20GB)) { return "D:\e-disk" }
  $root = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return (Join-Path $root "e-disk")
}

$Work = Get-WorkRoot
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$BaseVhd = Join-Path $Work "base.vhdx"
$BaseZst = Join-Path $Work "base.vhdx.zst"
$DiffVhd = Join-Path $Work "diff.vhdx"
$DiffZst = Join-Path $Work "diff.vhdx.zst"
$ConfPath = Join-Path $Work "rclone.conf"
$NeedBaseFlag = Join-Path $Work "need-base-upload.flag"
$BaselinePath = Join-Path $Work "boot-baseline.json"

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

function Get-ZstdExe {
  $dir = Join-Path $Work "zstd"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $exe = Get-ChildItem $dir -Recurse -Filter zstd.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
  if ($exe) { return $exe }
  $zip = Join-Path $dir "zstd.zip"
  curl.exe -fsSL -o $zip "https://github.com/facebook/zstd/releases/download/v1.5.6/zstd-v1.5.6-win64.zip"
  Expand-Archive $zip $dir -Force
  return (Get-ChildItem $dir -Recurse -Filter zstd.exe | Select-Object -First 1 -ExpandProperty FullName)
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
  if (-not (Test-Path $ConfPath)) {
    [IO.File]::WriteAllText($ConfPath, "[r2]`r`ntype = s3`r`nprovider = Cloudflare`r`nregion = auto`r`nno_check_bucket = true`r`n", (New-Object System.Text.UTF8Encoding($false)))
  }
  $env:RCLONE_CONFIG = $ConfPath
}

function Invoke-Rclone([string[]]$RcloneArgs) {
  $rclone = Get-RcloneExe
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out = & $rclone @RcloneArgs 2>&1
    $code = $LASTEXITCODE
    $out | Where-Object { [string]$_ -notmatch "NOTICE:" } | ForEach-Object { Write-Host $_ }
    if ($code -ne 0) { throw "rclone failed exit=$code args=$($RcloneArgs -join ' ')" }
  } finally {
    $ErrorActionPreference = $old
  }
}

function Get-RemoteRoot {
  $p = "$($env:R2_E_PREFIX)".Trim("/")
  if ($p) { return "r2:$($env:R2_BUCKET)/$p" }
  return "r2:$($env:R2_BUCKET)"
}

function Get-RemoteFiles {
  $rclone = Get-RcloneExe
  $remote = Get-RemoteRoot
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out = & $rclone lsf $remote --max-depth 1 2>&1
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($out | Where-Object { $_ -and ([string]$_ -notmatch "NOTICE|ERROR") } | ForEach-Object { ([string]$_).Trim() })
  } finally {
    $ErrorActionPreference = $old
  }
}

function Mount-VhdAsDrive([string]$VhdPath, [string]$DriveLetter) {
  $mimg = Mount-DiskImage -ImagePath $VhdPath -PassThru
  $mdisk = $mimg | Get-Disk
  if ($mdisk.IsOffline) {
    Set-Disk -Number $mdisk.Number -IsOffline $false
  }
  if ($mdisk.IsReadOnly) {
    Set-Disk -Number $mdisk.Number -IsReadOnly $false
  }
  $mpart = Get-Partition -DiskNumber $mdisk.Number -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -ne "Reserved" -and $_.Size -gt 100MB } |
    Select-Object -First 1
  if (-not $mpart) {
    $mpart = Get-Partition -DiskNumber $mdisk.Number -ErrorAction SilentlyContinue | Select-Object -Last 1
  }
  if (-not $mpart) {
    throw "e-disk: no partition found on mounted VHDX $VhdPath"
  }
  if ([string]$mpart.DriveLetter -ne $DriveLetter) {
    Set-Partition -DiskNumber $mdisk.Number -PartitionNumber $mpart.PartitionNumber -NewDriveLetter $DriveLetter
  }
}

function Invoke-Mount {
  Set-RcloneR2Env
  Save-BootBaseline

  if (Test-Path "${Letter}:\") {
    Write-Host "e-disk: ${Letter}: already mounted"
    return
  }

  $rclone = Get-RcloneExe
  $zstd = Get-ZstdExe
  $remote = Get-RemoteRoot
  $tBoot = Get-Date

  $files = @(Get-RemoteFiles)
  Write-Host ("e-disk: remote={0} top-level objects: {1}" -f $remote, ($files -join ", "))

  if (Test-Path $DiffVhd) {
    try { Dismount-DiskImage -ImagePath $DiffVhd -ErrorAction SilentlyContinue | Out-Null } catch {}
    Remove-Item $DiffVhd -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path $BaseVhd) {
    try { Dismount-DiskImage -ImagePath $BaseVhd -ErrorAction SilentlyContinue | Out-Null } catch {}
    Remove-Item $BaseVhd -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path $NeedBaseFlag) { Remove-Item $NeedBaseFlag -Force -ErrorAction SilentlyContinue }

  if ($files -contains "base.vhdx.zst") {
    # Standard B2 path: download base.vhdx.zst (+ optional diff.vhdx.zst), decompress on local NVMe, attach diff.vhdx
    $tDown = Get-Date
    Invoke-Rclone @("copy", "$remote/base.vhdx.zst", $Work, "--local-no-sparse", "--multi-thread-streams", "16", "--stats", "0")
    if (-not (Test-Path $BaseZst)) { throw "e-disk: download base.vhdx.zst failed" }
    $zstMB = (Get-Item $BaseZst).Length / 1MB
    $downSec = ((Get-Date) - $tDown).TotalSeconds
    Write-Host ("e-disk: downloaded base.vhdx.zst size={0:N1}MB seconds={1:N2} MBps={2:N1}" -f $zstMB, $downSec, ($zstMB / [Math]::Max($downSec, 0.01)))

    $tDec = Get-Date
    & $zstd -q -d -T0 -f $BaseZst -o $BaseVhd
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $BaseVhd)) { throw "e-disk: decompress base.vhdx.zst failed" }
    Remove-Item $BaseZst -Force -ErrorAction SilentlyContinue
    $rawMB = (Get-Item $BaseVhd).Length / 1MB
    $decSec = ((Get-Date) - $tDec).TotalSeconds
    Write-Host ("e-disk: decompressed base.vhdx size={0:N1}MB seconds={1:N2} MBps={2:N1}" -f $rawMB, $decSec, ($rawMB / [Math]::Max($decSec, 0.01)))

    if ($files -contains "diff.vhdx.zst") {
      $tDiff = Get-Date
      Invoke-Rclone @("copy", "$remote/diff.vhdx.zst", $Work, "--local-no-sparse", "--multi-thread-streams", "16", "--stats", "0")
      if (-not (Test-Path $DiffZst)) { throw "e-disk: download diff.vhdx.zst failed" }
      $diffZstMB = (Get-Item $DiffZst).Length / 1MB
      & $zstd -q -d -T0 -f $DiffZst -o $DiffVhd
      if ($LASTEXITCODE -ne 0 -or -not (Test-Path $DiffVhd)) { throw "e-disk: decompress diff.vhdx.zst failed" }
      Remove-Item $DiffZst -Force -ErrorAction SilentlyContinue
      try {
        Set-VHD -Path $DiffVhd -ParentPath $BaseVhd -IgnoreIdMismatch -ErrorAction SilentlyContinue
      } catch {}
      Write-Host ("e-disk: restored diff.vhdx.zst ({0:N1}MB) in {1:N2}s" -f $diffZstMB, ((Get-Date) - $tDiff).TotalSeconds)
    } else {
      New-VHD -ParentPath $BaseVhd -Path $DiffVhd -Differencing | Out-Null
      Write-Host "e-disk: created new differencing VHDX on top of base.vhdx"
    }
  } elseif ($files -contains "e.vhdx") {
    # Automatic migration from legacy uncompressed e.vhdx -> base.vhdx.zst on next save
    Write-Host "e-disk: migrating legacy e.vhdx from R2 to base.vhdx.zst architecture"
    $tDown = Get-Date
    $legacyPath = Join-Path $Work "e.vhdx"
    Invoke-Rclone @("copy", "$remote/e.vhdx", $Work, "--local-no-sparse", "--multi-thread-streams", "16", "--stats", "0")
    if (-not (Test-Path $legacyPath)) { throw "e-disk: download legacy e.vhdx failed" }
    Move-Item $legacyPath $BaseVhd -Force
    & fsutil sparse setflag $BaseVhd 0 2>$null | Out-Null
    $rawMB = (Get-Item $BaseVhd).Length / 1MB
    $downSec = ((Get-Date) - $tDown).TotalSeconds
    Write-Host ("e-disk: downloaded legacy e.vhdx size={0:N1}MB seconds={1:N2}" -f $rawMB, $downSec)
    Set-Content -Path $NeedBaseFlag -Value "migrated_from_evhdx" -Encoding UTF8
  } else {
    # Brand-new 100GB dynamic VHDX
    Write-Host "e-disk: initializing fresh 100GB dynamic base.vhdx"
    New-VHD -Path $BaseVhd -SizeBytes 100GB -Dynamic | Out-Null
    $img = Mount-DiskImage -ImagePath $BaseVhd -PassThru
    $disk = $img | Get-Disk
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru |
      New-Partition -UseMaximumSize -DriveLetter $Letter |
      Format-Volume -FileSystem NTFS -NewFileSystemLabel "persist" -Confirm:$false | Out-Null
    Dismount-DiskImage -ImagePath $BaseVhd | Out-Null
    Start-Sleep -Seconds 1
    Set-Content -Path $NeedBaseFlag -Value "fresh_base" -Encoding UTF8
  }

  $targetVhd = if (Test-Path $DiffVhd) { $DiffVhd } else { $BaseVhd }
  $tMnt = Get-Date
  Mount-VhdAsDrive -VhdPath $targetVhd -DriveLetter $Letter
  # Reset $RECYCLE.BIN on E: so cross-machine runner SID differences never trigger
  # "The Recycle Bin on E:\ is corrupted" popup in RDP Explorer.
  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & cmd.exe /c "rd /s /q ${Letter}:\`$RECYCLE.BIN" 2>$null | Out-Null
  $ErrorActionPreference = $oldEap
  $mntSec = ((Get-Date) - $tMnt).TotalSeconds
  $totSec = ((Get-Date) - $tBoot).TotalSeconds
  $up = Test-Path "${Letter}:\"
  Write-Host ("e-disk: ${Letter}: visible={0} vhd={1} mode=vhdx-zstd-diff mount_sec={2:N2} total_sec={3:N2}" -f $up, (Split-Path $targetVhd -Leaf), $mntSec, $totSec)
  if (-not $up) { throw "e-disk: ${Letter}: failed to mount" }
}

function Invoke-Save {
  Set-RcloneR2Env
  $rclone = Get-RcloneExe
  $zstd = Get-ZstdExe
  $remote = Get-RemoteRoot
  $tSave = Get-Date

  if (Test-Path "${Letter}:\") {
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & cmd.exe /c "rd /s /q ${Letter}:\`$RECYCLE.BIN" 2>$null | Out-Null
    $ErrorActionPreference = $oldEap
    try { Write-VolumeCache -DriveLetter $Letter -ErrorAction SilentlyContinue } catch {}
  }

  if (Test-Path $DiffVhd) {
    try { Dismount-DiskImage -ImagePath $DiffVhd -ErrorAction SilentlyContinue | Out-Null } catch {}
  }
  if (Test-Path $BaseVhd) {
    try { Dismount-DiskImage -ImagePath $BaseVhd -ErrorAction SilentlyContinue | Out-Null } catch {}
  }

  for ($i = 0; $i -lt 20; $i++) {
    if (-not (Test-Path "${Letter}:\")) { break }
    Start-Sleep -Milliseconds 250
  }
  if (Test-Path "${Letter}:\") {
    throw "e-disk: ${Letter}: still mounted after Dismount-DiskImage"
  }

  if (-not (Test-Path $DiffVhd) -and -not (Test-Path $BaseVhd)) {
    Write-Host "e-disk: no local VHDX found to save"
    return
  }

  $mergeThresholdGB = if ($env:E_DIFF_MERGE_GB) { [double]$env:E_DIFF_MERGE_GB } else { 3.0 }
  $diffBytes = if (Test-Path $DiffVhd) { (Get-Item $DiffVhd).Length } else { 0 }
  $doBaseMerge = (Test-Path $NeedBaseFlag) -or ($env:E_FORCE_BASE_MERGE -eq "1") -or ($diffBytes -ge ($mergeThresholdGB * 1GB))

  if ($doBaseMerge) {
    $reason = if (Test-Path $NeedBaseFlag) { (Get-Content $NeedBaseFlag -Raw).Trim() } elseif ($env:E_FORCE_BASE_MERGE -eq "1") { "forced" } else { "diff_threshold_exceeded" }
    Write-Host ("e-disk: merging diff.vhdx ({0:N1}MB) into base.vhdx (reason={1})" -f ($diffBytes / 1MB), $reason)
    if (Test-Path $DiffVhd) {
      Merge-VHD -Path $DiffVhd -DestinationPath $BaseVhd
      Remove-Item $DiffVhd -Force -ErrorAction SilentlyContinue
    }
    $rawBytes = (Get-Item $BaseVhd).Length
    $rawMB = $rawBytes / 1MB
    $tComp = Get-Date
    & $zstd -q -1 -T0 -f $BaseVhd -o $BaseZst
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $BaseZst)) { throw "e-disk: zstd compress base.vhdx failed" }
    $compSec = ((Get-Date) - $tComp).TotalSeconds
    $zstBytes = (Get-Item $BaseZst).Length
    $zstMB = $zstBytes / 1MB
    Write-Host ("e-disk: compressed base.vhdx raw={0:N1}MB -> zst={1:N1}MB ({2:P1}) in {3:N2}s ({4:N1} MB/s)" -f $rawMB, $zstMB, ($zstBytes / [double][Math]::Max($rawBytes, 1)), $compSec, ($rawMB / [Math]::Max($compSec, 0.01)))

    $tUp = Get-Date
    Invoke-Rclone @("copyto", $BaseZst, "$remote/base.vhdx.zst", "--s3-chunk-size", "64M", "--s3-upload-concurrency", "16", "--stats", "0")
    $upSec = ((Get-Date) - $tUp).TotalSeconds
    Remove-Item $BaseZst -Force -ErrorAction SilentlyContinue
    if (Test-Path $NeedBaseFlag) { Remove-Item $NeedBaseFlag -Force -ErrorAction SilentlyContinue }

    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $rclone deletefile "$remote/diff.vhdx.zst" 2>$null | Out-Null
    $ErrorActionPreference = $old

    Write-Host ("e-disk: uploaded base.vhdx.zst ({0:N1}MB) in {1:N2}s ({2:N1} MB/s), total_save={3:N2}s" -f $zstMB, $upSec, ($zstMB / [Math]::Max($upSec, 0.01)), ((Get-Date) - $tSave).TotalSeconds)
  } else {
    $rawMB = $diffBytes / 1MB
    $tComp = Get-Date
    & $zstd -q -1 -T0 -f $DiffVhd -o $DiffZst
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $DiffZst)) { throw "e-disk: zstd compress diff.vhdx failed" }
    $compSec = ((Get-Date) - $tComp).TotalSeconds
    $zstBytes = (Get-Item $DiffZst).Length
    $zstMB = $zstBytes / 1MB
    Write-Host ("e-disk: compressed diff.vhdx raw={0:N1}MB -> zst={1:N1}MB ({2:P1}) in {3:N2}s ({4:N1} MB/s)" -f $rawMB, $zstMB, ($zstBytes / [double][Math]::Max($diffBytes, 1)), $compSec, ($rawMB / [Math]::Max($compSec, 0.01)))

    $tUp = Get-Date
    Invoke-Rclone @("copyto", $DiffZst, "$remote/diff.vhdx.zst", "--s3-chunk-size", "64M", "--s3-upload-concurrency", "16", "--stats", "0")
    $upSec = ((Get-Date) - $tUp).TotalSeconds
    Remove-Item $DiffZst -Force -ErrorAction SilentlyContinue
    Write-Host ("e-disk: uploaded diff.vhdx.zst ({0:N1}MB) in {1:N2}s ({2:N1} MB/s), total_save={3:N2}s" -f $zstMB, $upSec, ($zstMB / [Math]::Max($upSec, 0.01)), ((Get-Date) - $tSave).TotalSeconds)
  }
}

if ($Action -eq "mount") { Invoke-Mount } else { Invoke-Save }
