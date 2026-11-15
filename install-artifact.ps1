# 把 GitHub Actions 产出的 kwin 安装到平板
# 用法：
#   .\install-artifact.ps1 -ArtifactZip "$env:USERPROFILE\Downloads\kwin-anland-arm64.zip"
#   .\install-artifact.ps1 -ArtifactZip <zip> -Rollback     # 回滚到上一次备份
param(
  [Parameter(Mandatory = $false)][string]$ArtifactZip,
  [string]$Adb = 'D:\MuMuPlayer\nx_main\adb.exe',
  [string]$Serial = 'HA29C5M4',
  [switch]$Rollback,
  [switch]$SkipRestart
)
$ErrorActionPreference = 'Stop'

function Invoke-Adb { param([string[]]$CmdArgs) & $Adb -s $Serial @CmdArgs }

if ($Rollback) {
  $sh = @'
P=/data/data/com.termux/files/usr
export PREFIX=$P HOME=/data/data/com.termux/files/home TMPDIR=$P/tmp PATH=$P/bin:/system/bin
R=$P/var/lib/proot-distro/containers/debian-anland/rootfs
B=$R/root/kwin_prev_gh
echo "rollback from: $B"
ls -l $B 2>/dev/null || { echo "no backup"; exit 3; }
cp -f "$B/libkwin.so.6.3.6" "$R/usr/lib/aarch64-linux-gnu/libkwin.so.6.3.6"
[ -f "$B/kwin_wayland" ] && cp -f "$B/kwin_wayland" "$R/usr/bin/kwin_wayland"
chmod 755 "$R/usr/lib/aarch64-linux-gnu/libkwin.so.6.3.6" "$R/usr/bin/kwin_wayland"
$P/bin/proot-distro login debian-anland --shared-tmp -- /sbin/ldconfig
echo "rollback done"
'@ -replace "`r`n", "`n"
  $tmp = [IO.Path]::GetTempFileName() + '.sh'
  [IO.File]::WriteAllText($tmp, $sh)
  Invoke-Adb @('push', $tmp, '/data/local/tmp/kwin_rollback.sh') | Out-Null
  Invoke-Adb @('shell', 'run-as com.termux /data/data/com.termux/files/usr/bin/bash /data/local/tmp/kwin_rollback.sh')
  return
}

if (-not $ArtifactZip -or -not (Test-Path $ArtifactZip)) { throw "ArtifactZip 不存在：$ArtifactZip" }

$work = Join-Path $env:TEMP ("kwin-art-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
Expand-Archive -Path $ArtifactZip -DestinationPath $work -Force
$lib = Join-Path $work 'libkwin.so.6.3.6'
$kw = Join-Path $work 'kwin_wayland'
if (-not (Test-Path $lib)) { throw "zip 里找不到 libkwin.so.6.3.6" }
if (-not (Test-Path $kw)) { throw "zip 里找不到 kwin_wayland" }

"local sha256:"
Get-FileHash $lib, $kw -Algorithm SHA256 | ForEach-Object { "  {0}  {1}" -f $_.Hash, (Split-Path $_.Path -Leaf) }

Invoke-Adb @('push', $lib, '/data/local/tmp/kwin_gh/libkwin.so.6.3.6') | Out-Null
Invoke-Adb @('push', $kw, '/data/local/tmp/kwin_gh/kwin_wayland') | Out-Null

$sh = @'
P=/data/data/com.termux/files/usr
export PREFIX=$P HOME=/data/data/com.termux/files/home TMPDIR=$P/tmp PATH=$P/bin:/system/bin
R=$P/var/lib/proot-distro/containers/debian-anland/rootfs
L=$R/usr/lib/aarch64-linux-gnu/libkwin.so.6.3.6
K=$R/usr/bin/kwin_wayland
set -e
# 1) 备份（首次安装才建，避免覆盖真正的“出厂备份”）
mkdir -p $R/root/kwin_prev_gh
[ -f $R/root/kwin_prev_gh/.done ] || {
  cp -f "$L" $R/root/kwin_prev_gh/libkwin.so.6.3.6
  cp -f "$K" $R/root/kwin_prev_gh/kwin_wayland
  date > $R/root/kwin_prev_gh/.done
  echo "backup created"
}
# 2) 覆盖
install -m 755 /data/local/tmp/kwin_gh/libkwin.so.6.3.6 "$L"
install -m 755 /data/local/tmp/kwin_gh/kwin_wayland "$K"
# 3) 校验符号
echo "--- strings check ---"
strings "$L" | grep -c -E 'anland_tablet_feed|flushTabletTools' || true
strings "$L" | grep -c 'setTabletMode' || true
# 4) ldconfig
$P/bin/proot-distro login debian-anland --shared-tmp -- /sbin/ldconfig
echo "install done"
'@ -replace "`r`n", "`n"
$tmp2 = [IO.Path]::GetTempFileName() + '.sh'
[IO.File]::WriteAllText($tmp2, $sh)
Invoke-Adb @('push', $tmp2, '/data/local/tmp/kwin_install_gh.sh') | Out-Null
Invoke-Adb @('shell', 'run-as com.termux /data/data/com.termux/files/usr/bin/bash /data/local/tmp/kwin_install_gh.sh')

if (-not $SkipRestart) {
  "restarting session..."
  Invoke-Adb @('shell', 'run-as com.termux /data/data/com.termux/files/usr/bin/bash /data/local/tmp/stack-up.sh')
  Start-Sleep -Seconds 5
  Invoke-Adb @('shell', 'run-as com.termux /data/data/com.termux/files/usr/bin/bash -c "for p in /proc/[0-9]*/comm; do c=$(cat $p 2>/dev/null); [ \"$c\" = kwin_wayland ] && echo KWIN; done | wc -l"')
}
