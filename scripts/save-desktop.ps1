$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Start-Transcript -Path "$env:USERPROFILE\Desktop\save-image.log" -Force
try {
  $cfg = Get-Content "$env:USERPROFILE\win-rdp-src\env.json" -Raw | ConvertFrom-Json
  $env:GITHUB_TOKEN = $cfg.GITHUB_TOKEN
  $env:GITHUB_REPOSITORY = $cfg.GITHUB_REPOSITORY
  if ($cfg.SNAPSHOT_REPO) { $env:SNAPSHOT_REPO = $cfg.SNAPSHOT_REPO }
  Set-Location "$env:USERPROFILE\win-rdp-src"
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\c-image.ps1 -Action save
  [System.Windows.Forms.MessageBox]::Show("C 盘增量已保存到 GitHub Release tag c-image（含用户文件/注册表/环境变量，Claude 登录单独一层）。下次开机 restore。", "保存镜像")
} catch {
  [System.Windows.Forms.MessageBox]::Show("保存失败: $_", "保存镜像")
}
Stop-Transcript
