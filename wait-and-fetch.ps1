# 等待 GitHub Actions 的 build-kwin-arm64 跑完，并把产物 (libkwin.so.6.3.6 / kwin_wayland / SHA256SUMS.txt) 拉到 out\gh\
# 用法: powershell -ExecutionPolicy Bypass -File wait-and-fetch.ps1 [-MaxMinutes 90]
param(
  [int]$MaxMinutes = 90,
  [string]$RunId = ""
)
$ErrorActionPreference = 'Continue'
$repo = 'devkaij/Linux-yoga'
$h = @{ 'User-Agent' = 'dsh' }

function Get-Token {
  $inp = "protocol=https`nhost=github.com`n`n"
  $out = $inp | & "C:\Program Files\Git\mingw64\bin\git-credential-manager.exe" get 2>$null
  return (($out | Where-Object { $_ -like 'password=*' }) -replace '^password=', '')
}

$tok = Get-Token
$ah = @{ 'User-Agent' = 'dsh'; 'Authorization' = "Bearer $tok" }

if (-not $RunId) {
  $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs?per_page=1" -Headers $h
  $RunId = $r.workflow_runs[0].id
}
Write-Output "run=$RunId watching (max $MaxMinutes min)"

$deadline = (Get-Date).AddMinutes($MaxMinutes)
$last = ""
while ((Get-Date) -lt $deadline) {
  $run = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs/$RunId" -Headers $h
  $jobs = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs/$RunId/jobs" -Headers $h
  $step = ($jobs.jobs[0].steps | Where-Object { $_.status -eq 'in_progress' } | Select-Object -First 1).name
  $done = ($jobs.jobs[0].steps | Where-Object { $_.conclusion -eq 'success' }).Count
  $line = "{0} status={1} concl={2} step={3} done={4}" -f (Get-Date -Format HH:mm:ss), $run.status, $run.conclusion, $step, $done
  if ($line -ne $last) { Write-Output $line; $last = $line }
  if ($run.status -eq 'completed') { break }
  Start-Sleep -Seconds 60
}

$run = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs/$RunId" -Headers $h
if ($run.conclusion -ne 'success') {
  Write-Output "RESULT=$($run.conclusion)"
  # 抓失败日志的 Compile 步骤尾部
  try {
    $zip = "$env:TEMP\ghlogs-$RunId.zip"
    Invoke-WebRequest -Uri "https://api.github.com/repos/$repo/actions/runs/$RunId/logs" -Headers $ah -OutFile $zip -ErrorAction Stop
    $dir = "$env:TEMP\ghlogs-$RunId"
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive $zip -DestinationPath $dir -Force
    $f = Get-ChildItem $dir -Recurse -File -Filter '8_Compile.txt' | Select-Object -First 1
    if ($f) { Write-Output '--- compile tail ---'; Get-Content $f.FullName -Encoding utf8 | Select-Object -Last 25 }
  } catch { Write-Output "log fetch failed: $($_.Exception.Message)" }
  exit 1
}

Write-Output "RESULT=success; downloading artifacts"
$arts = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs/$RunId/artifacts" -Headers $h
$outDir = Join-Path $PSScriptRoot 'out\gh'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
foreach ($a in $arts.artifacts) {
  $zp = Join-Path $outDir ($a.name + '.zip')
  Invoke-WebRequest -Uri "https://api.github.com/repos/$repo/actions/artifacts/$($a.id)/zip" -Headers $ah -OutFile $zp
  Write-Output ("artifact {0} -> {1} ({2} bytes)" -f $a.name, $zp, (Get-Item $zp).Length)
  Expand-Archive $zp -DestinationPath $outDir -Force
}
Get-ChildItem $outDir -File | ForEach-Object { "{0}  {1} bytes" -f $_.Name, $_.Length }
if (Test-Path (Join-Path $outDir 'SHA256SUMS.txt')) {
  Write-Output '--- SHA256SUMS.txt ---'
  Get-Content (Join-Path $outDir 'SHA256SUMS.txt')
}
Write-Output 'DONE'
