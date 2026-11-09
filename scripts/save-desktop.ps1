$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Start-Transcript -Path "$env:USERPROFILE\Desktop\save-image.log" -Force
try {
  $cfg = Get-Content "$env:USERPROFILE\win-rdp-src\env.json" -Raw | ConvertFrom-Json
  $env:GITHUB_TOKEN = $cfg.GITHUB_TOKEN
  $env:GITHUB_REPOSITORY = $cfg.GITHUB_REPOSITORY
  if ($cfg.SNAPSHOT_REPO) { $env:SNAPSHOT_REPO = $cfg.SNAPSHOT_REPO }
  Set-Location "$env:USERPROFILE\win-rdp-src"
  if (Test-Path "E:\") {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\c-image.ps1 -Action save -TargetDir "E:\CloudVM-C"
    [System.Windows.Forms.MessageBox]::Show("C 盘增量已写入 E:\\CloudVM-C。关机时会随 E 盘上传。", "保存镜像")
  } else {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\c-image.ps1 -Action save
    [System.Windows.Forms.MessageBox]::Show("E: 不在，已退回 GitHub Release zip。", "保存镜像")
  }
} catch {
  [System.Windows.Forms.MessageBox]::Show("保存失败: $_", "保存镜像")
}
Stop-Transcript
