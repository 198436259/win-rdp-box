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
  $remote = Get-OssVhd
  $listed = Invoke-Rclone @("lsf", "oss:$($env:OSS_BUCKET)/", "--include", "e.vhdx")
  $has = $false
  foreach ($line in @($listed)) {
    if (([string]$line).Trim() -match "^e\.vhdx$") { $has = $true }
  }
  if ($has) {
    Write-Host "e-disk: downloading e.vhdx"
    Invoke-Rclone @("copy", $remote, "D:\", "--progress") | Out-Null
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
  Write-Host "e-disk: uploading bytes=$((Get-Item $Vhd).Length)"
  Invoke-Rclone @("copy", $Vhd, "oss:$($env:OSS_BUCKET)/", "--progress") | Out-Null
  Invoke-Rclone @("ls", "oss:$($env:OSS_BUCKET)/e.vhdx") | Out-Null
  Write-Host "e-disk: uploaded e.vhdx"
}

if ($Action -eq "mount") { Invoke-Mount } else { Invoke-Save }
