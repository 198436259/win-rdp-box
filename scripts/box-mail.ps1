param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("get", "put", "delete")]
  [string]$Action,
  [Parameter(Mandatory = $true)]
  [string]$RelPath,
  [string]$Content = ""
)

$ErrorActionPreference = "Stop"

function Get-Repo {
  if ($env:SNAPSHOT_REPO) { return $env:SNAPSHOT_REPO }
  if ($env:GITHUB_REPOSITORY) { return $env:GITHUB_REPOSITORY }
  throw "SNAPSHOT_REPO missing"
}

function Get-Headers {
  if (-not $env:GITHUB_TOKEN) { throw "GITHUB_TOKEN missing" }
  return @{
    Authorization          = "Bearer $($env:GITHUB_TOKEN)"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
  }
}

function Get-ContentsUri([string]$path) {
  $repo = Get-Repo
  $enc = [uri]::EscapeDataString($path)
  return "https://api.github.com/repos/$repo/contents/$enc"
}

function Get-Meta([string]$path) {
  try {
    return Invoke-RestMethod -Headers (Get-Headers) -Uri (Get-ContentsUri $path)
  } catch {
    $resp = $_.Exception.Response
    if ($resp -and [int]$resp.StatusCode -eq 404) { return $null }
    throw
  }
}

switch ($Action) {
  "get" {
    $meta = Get-Meta $RelPath
    if (-not $meta) { return }
    $raw = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($meta.content.Replace("`n", "")))
    Write-Output $raw
  }
  "put" {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Content)
    $b64 = [Convert]::ToBase64String($bytes)
    $meta = Get-Meta $RelPath
    $bodyObj = @{
      message = "box $($RelPath)"
      content = $b64
    }
    if ($meta.sha) { $bodyObj.sha = $meta.sha }
    $body = $bodyObj | ConvertTo-Json -Compress
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("box-" + [guid]::NewGuid().ToString() + ".json")
    [IO.File]::WriteAllText($tmp, $body)
    try {
      $code = & curl.exe -sS -o "$tmp.out" -w "%{http_code}" -X PUT `
        -H "Authorization: Bearer $($env:GITHUB_TOKEN)" `
        -H "Accept: application/vnd.github+json" `
        -H "X-GitHub-Api-Version: 2022-11-28" `
        -H "Content-Type: application/json" `
        --data-binary "@$tmp" `
        (Get-ContentsUri $RelPath)
      if ($code -ne "200" -and $code -ne "201") {
        Get-Content "$tmp.out" -ErrorAction SilentlyContinue | Select-Object -First 20
        throw "box put http=$code path=$RelPath"
      }
    } finally {
      Remove-Item $tmp, "$tmp.out" -ErrorAction SilentlyContinue
    }
  }
  "delete" {
    $meta = Get-Meta $RelPath
    if (-not $meta) { return }
    $body = (@{ message = "box delete $($RelPath)"; sha = $meta.sha } | ConvertTo-Json -Compress)
    Invoke-RestMethod -Method DELETE -Headers (Get-Headers) -ContentType "application/json" -Uri (Get-ContentsUri $RelPath) -Body $body | Out-Null
  }
}
