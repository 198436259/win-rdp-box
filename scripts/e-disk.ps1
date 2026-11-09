param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("mount", "save")]
  [string]$Action
)

$ErrorActionPreference = "Stop"
$Vhd = "D:\e.vhdx"
$Label = "persist"
$Letter = "E"

function Get-RcloneExe {
  $dir = Join-Path $env:RUNNER_TEMP "rclone"
  if (-not $env:RUNNER_TEMP) { $dir = Join-Path $env:TEMP "rclone" }
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $exe = Get-ChildItem $dir -Recurse -Filter rclone.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
  if ($exe) { return $exe }
  $zip = Join-Path $dir "rclone.zip"
  curl.exe -fsSL -o $zip "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
  Expand-Archive $zip $dir -Force
  return (Get-ChildItem $dir -Recurse -Filter rclone.exe | Select-Object -First 1 -ExpandProperty FullName)
}

function Set-RcloneOssEnv {
  if (-not $env:OSS_ACCESS_KEY_ID) { throw "OSS_ACCESS_KEY_ID missing" }
  if (-not $env:OSS_ACCESS_KEY_SECRET) { throw "OSS_ACCESS_KEY_SECRET missing" }
  if (-not $env:OSS_BUCKET) { throw "OSS_BUCKET missing" }
  if (-not $env:OSS_ENDPOINT) { throw "OSS_ENDPOINT missing" }
  $env:RCLONE_CONFIG_OSS_TYPE = "s3"
  $env:RCLONE_CONFIG_OSS_PROVIDER = "Alibaba"
  $env:RCLONE_CONFIG_OSS_ACCESS_KEY_ID = $env:OSS_ACCESS_KEY_ID
  $env:RCLONE_CONFIG_OSS_SECRET_ACCESS_KEY = $env:OSS_ACCESS_KEY_SECRET
  $env:RCLONE_CONFIG_OSS_ENDPOINT = $env:OSS_ENDPOINT
}

function Get-OssVhd {
  return "oss:$($env:OSS_BUCKET)/e.vhdx"
}

function Invoke-Rclone {
  param([string[]]$RcloneArgs)
  $exe = Get-RcloneExe
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out = & $exe @RcloneArgs 2>&1
    $code = $LASTEXITCODE
    $lines = @()
    foreach ($item in @($out)) {
      $text = [string]$item
      if ($text -match "NOTICE: Config file") { continue }
      if ($item -is [System.Management.Automation.ErrorRecord] -and $text -match "NOTICE:") { continue }
      $lines += $text
      if ($item -is [System.Management.Automation.ErrorRecord] -and $text -notmatch "NOTICE:") {
        Write-Host $text
      } elseif ($item -isnot [System.Management.Automation.ErrorRecord]) {
        Write-Host $text
      }
    }
    if ($code -ne 0) { throw "rclone exit=$code args=$($RcloneArgs -join ' ')" }
    return $lines
  } finally {
    $ErrorActionPreference = $old
  }
}

function Wait-PersistVolume([int]$diskNumber) {
  for ($i = 0; $i -lt 20; $i++) {
    $vol = Get-Volume | Where-Object { $_.FileSystemLabel -eq $Label } | Select-Object -First 1
    if ($vol) { return $vol }
    $part = Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue |
      Where-Object { $_.Type -eq "Basic" -or $_.Size -gt 8MB } |
      Select-Object -First 1
    if ($part) {
      try { $v = $part | Get-Volume -ErrorAction SilentlyContinue } catch { $v = $null }
      if ($v) { return $v }
    }
    Start-Sleep -Milliseconds 500
  }
  return $null
}

function Set-Letter([object]$vol) {
  if (-not $vol) { return }
  $cur = [string]$vol.DriveLetter
  if ($cur -eq $Letter) { return }
  if ($cur) {
    Get-Partition -DriveLetter $cur | Set-Partition -NewDriveLetter $Letter
    return
  }
  $diskNumber = $null
  try { $diskNumber = (Get-Partition -Volume $vol).DiskNumber } catch {}
  if ($null -eq $diskNumber) { return }
  Get-Partition -DiskNumber $diskNumber |
    Where-Object { $_.Type -eq "Basic" -or $_.Size -gt 8MB } |
    Select-Object -First 1 |
    Set-Partition -NewDriveLetter $Letter
}

function Mount-Persist {
  $img = Mount-DiskImage -ImagePath $Vhd -PassThru
  $disk = $img | Get-Disk
  $raw = [string]$disk.PartitionStyle
  Write-Host ("e-disk: disk#={0} style={1} size={2}" -f $disk.Number, $raw, $disk.Size)
  if ($raw -eq "RAW" -or $raw -eq "") {
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru |
      New-Partition -UseMaximumSize -DriveLetter $Letter |
      Format-Volume -FileSystem NTFS -NewFileSystemLabel $Label -Confirm:$false | Out-Null
    return
  }
  $vol = Wait-PersistVolume $disk.Number
  if ($vol) {
    Set-Letter $vol
    return
  }
  $part = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq "Basic" -or $_.Size -gt 8MB } |
    Select-Object -First 1
  if ($part) {
    if (-not $part.DriveLetter) {
      $part | Set-Partition -NewDriveLetter $Letter
    } elseif ($part.DriveLetter -ne $Letter) {
      Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -NewDriveLetter $Letter
    }
    return
  }
  throw ("e-disk: mounted but no persist volume disk#={0} style={1}" -f $disk.Number, $raw)
}

function Invoke-Mount {
  Set-RcloneOssEnv
  $remote = Get-OssVhd
  if (Test-Path $Vhd) { Remove-Item $Vhd -Force }
  Write-Host "e-disk: trying download e.vhdx"
  $got = $false
  try {
    Invoke-Rclone @("copy", $remote, "D:\", "--progress") | Out-Null
    if ((Test-Path $Vhd) -and ((Get-Item $Vhd).Length -gt 1MB)) { $got = $true }
  } catch {
    Write-Host "e-disk: download failed: $_"
  }
  if ($got) {
    Write-Host "e-disk: downloaded bytes=$((Get-Item $Vhd).Length)"
  } else {
    Write-Host "e-disk: no remote e.vhdx, creating 100GB dynamic VHD (not uploaded)"
    if (Test-Path $Vhd) { Remove-Item $Vhd -Force }
    New-VHD -Path $Vhd -SizeBytes 100GB -Dynamic | Out-Null
  }
  Mount-Persist
  Start-Sleep -Seconds 1
  if (-not (Test-Path "E:\")) { throw "E: not mounted" }
  Write-Host "e-disk: mounted E: label=$Label"
}

function Invoke-Save {
  Set-RcloneOssEnv
  if (Get-DiskImage -ImagePath $Vhd -ErrorAction SilentlyContinue | Where-Object { $_.Attached }) {
    Dismount-DiskImage -ImagePath $Vhd | Out-Null
  }
  if (-not (Test-Path $Vhd)) { throw "D:\e.vhdx missing, skip upload not allowed" }
  Write-Host "e-disk: uploading bytes=$((Get-Item $Vhd).Length)"
  Invoke-Rclone @("copy", $Vhd, "oss:$($env:OSS_BUCKET)/", "--progress") | Out-Null
  Invoke-Rclone @("ls", "oss:$($env:OSS_BUCKET)/e.vhdx") | Out-Null
  Write-Host "e-disk: uploaded e.vhdx"
}

if ($Action -eq "mount") { Invoke-Mount } else { Invoke-Save }
