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

function Mount-Persist {
  $img = Mount-DiskImage -ImagePath $Vhd -PassThru
  $vol = Get-Volume | Where-Object { $_.FileSystemLabel -eq $Label } | Select-Object -First 1
  if (-not $vol) {
    $disk = $img | Get-Disk
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru |
      New-Partition -UseMaximumSize -DriveLetter $Letter |
      Format-Volume -FileSystem NTFS -NewFileSystemLabel $Label -Confirm:$false | Out-Null
    return
  }
  if ($vol.DriveLetter -ne $Letter) {
    if ($vol.DriveLetter) {
      Get-Partition -DriveLetter $vol.DriveLetter | Set-Partition -NewDriveLetter $Letter
    } else {
      Get-Disk -Number ($img | Get-Disk).Number | Get-Partition |
        Where-Object { $_.Type -eq "Basic" } |
        Set-Partition -NewDriveLetter $Letter
    }
  }
}

function Invoke-Mount {
  Set-RcloneOssEnv
  $exe = Get-RcloneExe
  $remote = Get-OssVhd
  $listed = & $exe lsf "oss:$($env:OSS_BUCKET)/" --include "e.vhdx" 2>$null
  $has = $false
  foreach ($line in @($listed)) {
    if ([string]$line -match "^e\.vhdx$") { $has = $true }
  }
  if ($has) {
    Write-Host "e-disk: downloading e.vhdx"
    & $exe copy $remote "D:\" --progress
    if (-not (Test-Path $Vhd)) { throw "e.vhdx not downloaded" }
    Write-Host "e-disk: downloaded bytes=$((Get-Item $Vhd).Length)"
  } else {
    Write-Host "e-disk: no remote e.vhdx, creating 100GB dynamic VHD (not uploaded)"
    if (Test-Path $Vhd) { Remove-Item $Vhd -Force }
    New-VHD -Path $Vhd -SizeBytes 100GB -Dynamic | Out-Null
  }
  Mount-Persist
  if (-not (Test-Path "E:\")) { throw "E: not mounted" }
  Write-Host "e-disk: mounted E: label=$Label"
}

function Invoke-Save {
  Set-RcloneOssEnv
  if (Get-DiskImage -ImagePath $Vhd -ErrorAction SilentlyContinue | Where-Object { $_.Attached }) {
    Dismount-DiskImage -ImagePath $Vhd | Out-Null
  }
  if (-not (Test-Path $Vhd)) { throw "D:\e.vhdx missing, skip upload not allowed" }
  $exe = Get-RcloneExe
  Write-Host "e-disk: uploading bytes=$((Get-Item $Vhd).Length)"
  & $exe copy $Vhd "oss:$($env:OSS_BUCKET)/" --progress
  & $exe ls "oss:$($env:OSS_BUCKET)/e.vhdx"
  Write-Host "e-disk: uploaded e.vhdx"
}

if ($Action -eq "mount") { Invoke-Mount } else { Invoke-Save }
