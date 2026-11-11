# End-to-end check: build a real 3.3GB VHDX, round-trip it through R2, mount it, write, re-upload.
# Uses its own object key (r2-e2e/e2e.vhdx) so the production e.vhdx is never touched.
$ErrorActionPreference = "Stop"

$SizeBytes = 3.3GB
$WorkRoot  = if (Test-Path "D:\") { "D:\r2e2e" } else { Join-Path $env:RUNNER_TEMP "r2e2e" }
$Vhd       = Join-Path $WorkRoot "e2e.vhdx"
$DownDir   = Join-Path $WorkRoot "dl"
$RemoteKey = "r2-e2e/e2e.vhdx"
$Label     = "persist"
$Letter    = "E"

function Write-Step([string]$name) {
  Write-Host ""
  Write-Host ("########## {0} ##########" -f $name)
}

function Write-Timing([string]$name, [double]$seconds, [double]$mb) {
  $rate = if ($seconds -gt 0) { $mb / $seconds } else { 0 }
  Write-Host ("TIMING {0} seconds={1:N1} MBps={2:N1}" -f $name, $seconds, $rate)
}

function Get-RcloneExe {
  $dir = Join-Path $env:RUNNER_TEMP "rclone"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $exe = Get-ChildItem $dir -Recurse -Filter rclone.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
  if ($exe) { return $exe }
  $zip = Join-Path $dir "rclone.zip"
  curl.exe -fsSL -o $zip "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
  Expand-Archive $zip $dir -Force
  return (Get-ChildItem $dir -Recurse -Filter rclone.exe | Select-Object -First 1 -ExpandProperty FullName)
}

function Set-RcloneR2Env {
  foreach ($n in "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_BUCKET", "R2_ENDPOINT") {
    if (-not (Get-Item "env:$n" -ErrorAction SilentlyContinue)) { throw "$n missing" }
  }
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
    $code = $LASTEXITCODE
    foreach ($item in @($out)) {
      $text = [string]$item
      if ($text -match "NOTICE: Config file") { continue }
      Write-Host $text
    }
    if ($code -ne 0) { throw "rclone exit=$code args=$($RcloneArgs -join ' ')" }
  } finally {
    $ErrorActionPreference = $old
  }
}

function Invoke-Diskpart([string]$scriptText) {
  $tmp = Join-Path $env:TEMP ("r2e2e-" + [guid]::NewGuid().ToString("N") + ".txt")
  [IO.File]::WriteAllText($tmp, $scriptText)
  try { & diskpart.exe /s $tmp 2>&1 | Out-String | Write-Host } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function New-TestVhd {
  New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
  if (Test-Path $Vhd) { Remove-Item $Vhd -Force }
  try {
    New-VHD -Path $Vhd -SizeBytes 100GB -Dynamic -ErrorAction Stop | Out-Null
    Write-Host "create: New-VHD ok"
  } catch {
    Write-Host "create: New-VHD failed ($_), falling back to diskpart"
    Invoke-Diskpart ("create vdisk file=`"$Vhd`" maximum=102400 type=expandable")
  }

  $img = Mount-DiskImage -ImagePath $Vhd -PassThru -ErrorAction Stop
  Start-Sleep -Seconds 2
  try { Update-HostStorageCache } catch {}
  $disk = $img | Get-Disk -ErrorAction Stop
  Write-Host ("create: disk#{0} style={1}" -f $disk.Number, $disk.PartitionStyle)
  if ([string]$disk.PartitionStyle -ne "RAW") {
    throw "create: fresh VHD came up non-RAW, refusing to touch it"
  }
  Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru |
    New-Partition -UseMaximumSize -DriveLetter $Letter |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel $Label -Confirm:$false | Out-Null
  Start-Sleep -Seconds 2
  if (-not (Test-Path "${Letter}:\")) { throw "create: ${Letter}: missing after format" }

  Write-Host ("create: writing {0:N1} GB pseudo-random data" -f ($SizeBytes / 1GB))
  $fill = Join-Path "${Letter}:\" "fill.bin"
  $buf = New-Object byte[] (4MB)
  $rnd = [Random]::new(11)
  $fs = [IO.File]::Open($fill, "Create", "Write", "None")
  try {
    $written = 0L
    while ($written -lt $SizeBytes) {
      $rnd.NextBytes($buf)
      $chunk = [Math]::Min([long]$buf.Length, $SizeBytes - $written)
      $fs.Write($buf, 0, [int]$chunk)
      $written += $chunk
    }
  } finally { $fs.Close() }
  Write-Host ("create: fill.bin bytes={0}" -f (Get-Item $fill).Length)

  $srcHash = (Get-FileHash $fill -Algorithm SHA256).Hash
  Write-Host "create: fill sha256=$srcHash"
  [IO.File]::WriteAllText((Join-Path $WorkRoot "fill.sha256"), $srcHash)
  [IO.File]::WriteAllText((Join-Path "${Letter}:\" "marker.txt"), "r2-e2e-marker")

  Dismount-DiskImage -ImagePath $Vhd | Out-Null
  Start-Sleep -Seconds 2
  Write-Host ("create: vhdx bytes={0}" -f (Get-Item $Vhd).Length)
}

function Test-Sparse([string]$path) {
  $out = & fsutil.exe sparse queryflag $path 2>&1 | Out-String
  Write-Host ("sparse query: " + $out.Trim())
  return ($out -match "is set")
}

function ConvertTo-Nonsparse([string]$path) {
  if (-not (Test-Sparse $path)) {
    Write-Host "nonsparse: already non-sparse, skip"
    return
  }
  $tmp = Join-Path (Split-Path $path) ("nonsparse-" + [IO.Path]::GetFileName($path))
  & cmd.exe /c "copy /y `"$path`" `"$tmp`""
  if (-not (Test-Path $tmp) -or ((Get-Item $tmp).Length -lt 1MB)) { throw "nonsparse: copy failed" }
  Remove-Item $path -Force
  Move-Item $tmp $path -Force
  Write-Host "nonsparse: done"
}

Write-Step "PREFLIGHT"
Get-Volume | Format-Table DriveLetter, FileSystemLabel, FileSystem, @{n = "SizeGB"; e = { [math]::Round($_.Size / 1GB, 1) } } -AutoSize | Out-String | Write-Host
Get-PSDrive -PSProvider FileSystem | Format-Table Name, @{n = "FreeGB"; e = { [math]::Round($_.Free / 1GB, 1) } } -AutoSize | Out-String | Write-Host
Set-RcloneR2Env

Write-Step "1 BUILD 3.3GB VHDX"
$t = Get-Date
New-TestVhd
$sec = ((Get-Date) - $t).TotalSeconds
Write-Timing "build" $sec ($SizeBytes / 1MB)
$vhdBytes = (Get-Item $Vhd).Length
Write-Host ("RESULT vhdx_bytes={0}" -f $vhdBytes)

Write-Step "2 UPLOAD 3.3GB TO R2"
$t = Get-Date
Invoke-Rclone @("copy", $Vhd, "r2:$($env:R2_BUCKET)/r2-e2e/", "--progress", "--stats-one-line")
$sec = ((Get-Date) - $t).TotalSeconds
Write-Timing "upload" $sec ($vhdBytes / 1MB)
Invoke-Rclone @("ls", "r2:$($env:R2_BUCKET)/$RemoteKey")

Write-Step "3 DELETE LOCAL, DOWNLOAD FROM R2"
Remove-Item $Vhd -Force
New-Item -ItemType Directory -Force -Path $DownDir | Out-Null
$t = Get-Date
Invoke-Rclone @("copy", "r2:$($env:R2_BUCKET)/$RemoteKey", $DownDir, "--progress", "--local-no-sparse", "--stats-one-line")
$sec = ((Get-Date) - $t).TotalSeconds
$dl = Join-Path $DownDir "e2e.vhdx"
if (-not (Test-Path $dl)) { throw "download: $dl missing" }
$dlBytes = (Get-Item $dl).Length
Write-Timing "download" $sec ($dlBytes / 1MB)
Write-Host ("RESULT downloaded_bytes={0} match_size={1}" -f $dlBytes, ($dlBytes -eq $vhdBytes))

Write-Step "4 NON-SPARSE + MOUNT"
$t = Get-Date
ConvertTo-Nonsparse $dl
$sec = ((Get-Date) - $t).TotalSeconds
Write-Timing "nonsparse" $sec ($dlBytes / 1MB)

$t = Get-Date
$img = Mount-DiskImage -ImagePath $dl -PassThru -ErrorAction Stop
Start-Sleep -Seconds 2
try { Update-HostStorageCache } catch {}
$disk = $img | Get-Disk -ErrorAction Stop
$vol = Get-Volume | Where-Object { $_.FileSystemLabel -eq $Label } | Select-Object -First 1
if (-not $vol) { throw "mount: no volume labelled $Label" }
if ([string]$vol.DriveLetter -ne $Letter) {
  $part = Get-Partition -Volume $vol
  Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -NewDriveLetter $Letter
  Start-Sleep -Seconds 2
}
$sec = ((Get-Date) - $t).TotalSeconds
Write-Timing "mount" $sec 0
if (-not (Test-Path "${Letter}:\")) { throw "mount: ${Letter}: missing" }
$mountedVol = Get-Volume -DriveLetter $Letter
Write-Host ("RESULT mounted disk#{0} letter={1} size={2:N1}GB" -f $disk.Number, $mountedVol.DriveLetter, ($mountedVol.Size / 1GB))

Write-Step "5 VERIFY DATA + WRITE"
$fill = Join-Path "${Letter}:\" "fill.bin"
$marker = Join-Path "${Letter}:\" "marker.txt"
if (-not (Test-Path $fill)) { throw "verify: fill.bin missing on mounted volume" }
if (-not (Test-Path $marker)) { throw "verify: marker.txt missing on mounted volume" }
$expect = [IO.File]::ReadAllText((Join-Path $WorkRoot "fill.sha256")).Trim()
Write-Host "verify: hashing 3.3GB fill.bin on mounted volume"
$t = Get-Date
$gotHash = (Get-FileHash $fill -Algorithm SHA256).Hash
$sec = ((Get-Date) - $t).TotalSeconds
Write-Host ("TIMING hashread seconds={0:N1}" -f $sec)
Write-Host ("RESULT fill_hash_match={0}" -f ($gotHash -eq $expect))

$newFile = Join-Path "${Letter}:\" "written-by-runner.txt"
[IO.File]::WriteAllText($newFile, "written at " + (Get-Date).ToString("o"))
$back = [IO.File]::ReadAllText($newFile)
Write-Host ("RESULT write_ok={0} content={1}" -f ($back.StartsWith("written at")), $back)

Write-Step "6 DISMOUNT + RE-UPLOAD"
$t = Get-Date
Dismount-DiskImage -ImagePath $dl | Out-Null
Start-Sleep -Seconds 2
$sec = ((Get-Date) - $t).TotalSeconds
Write-Timing "dismount" $sec 0

$t = Get-Date
Invoke-Rclone @("copy", $dl, "r2:$($env:R2_BUCKET)/r2-e2e/", "--progress", "--stats-one-line")
$sec = ((Get-Date) - $t).TotalSeconds
Write-Timing "reupload" $sec ($dlBytes / 1MB)

Write-Step "7 CLEANUP REMOTE"
$old = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& (Get-RcloneExe) delete "r2:$($env:R2_BUCKET)/r2-e2e/" 2>&1 | Out-Host
$ErrorActionPreference = $old

Write-Host ""
Write-Host "R2_E2E_DONE"
