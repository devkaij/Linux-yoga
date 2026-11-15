#!/data/data/com.termux/files/usr/bin/bash
# yoga-plasma-tawc.sh —— 用 tawcroot 跑 Plasma 会话（替代 proot-distro login，去掉 ptrace 税）
#
# 两种模式（prepare 时选）：
#   shared（默认，推荐）：直接用 proot 那份 rootfs，**不复制 8GB**。
#       做法＝在 store 目录写一个「未来版本号」把 tawcroot 逼进 DEGRADED 模式：
#       token 检测仍在，但**所有 linkstore 变更被拒绝**，guest 内 link() 退回真实 EPERM。
#       这样它就不会就地改写 rootfs 里的文件名，proot 那份继续可用；代价是 guest 内
#       建硬链接会失败（Android 上本来也是 EPERM）。
#   copy：复制一份专用 rootfs（≈8GB），保留完整硬链接仿真（.deb 安装、git gc 等更保真）。
#
# 用法：
#   yoga-plasma-tawc.sh prepare [shared|copy]
#   yoga-plasma-tawc.sh start | stop | status | bench
#
# 前提：$PREFIX/bin/tawcroot 已装（tawcroot-builder 产物）
set -u

PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
export PREFIX
export HOME=${HOME:-/data/data/com.termux/files/home}
export TMPDIR=${TMPDIR:-$PREFIX/tmp}
export PATH=$PREFIX/bin:/system/bin:$PATH

SRC_ROOTFS=$PREFIX/var/lib/proot-distro/containers/debian-anland/rootfs
WS=$HOME/workstation
COPY_ROOTFS=$WS/desktop-rootfs
MODE_FILE=$WS/tawc-mode
BOOT_SRC=${YOGA_BOOT_SRC:-$PREFIX/bin/yoga-plasma-boot.sh}
[ -f "$BOOT_SRC" ] || BOOT_SRC=$HOME/wl_stage/yoga-plasma-boot.sh
LOG=$HOME/wl_stage/tawc-plasma.log
TMP_BIND=$TMPDIR
# tawcroot 的 store 固定落在 rootfs 的同级目录
STORE_OF() { echo "$(dirname "$1")/tawcroot"; }

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

mode() { cat "$MODE_FILE" 2>/dev/null || echo ""; }
rootfs_of_mode() { [ "$(mode)" = "copy" ] && echo "$COPY_ROOTFS" || echo "$SRC_ROOTFS"; }
need_tawcroot() { [ -x "$PREFIX/bin/tawcroot" ] || { echo "缺 $PREFIX/bin/tawcroot"; exit 3; }; }

cnt_comm() {
  local n=0 c pid s
  for p in /proc/[0-9]*/comm; do
    c=$(cat "$p" 2>/dev/null); [ "$c" = "$1" ] || continue
    pid=${p#/proc/}; pid=${pid%/comm}
    s=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
    [ "$s" = "Z" ] && continue
    n=$((n+1))
  done
  echo $n
}

# 把 store 逼进 DEGRADED：version > 支持的 1（见 tawcroot src/linkstore.c version_gate）
mark_degraded() {
  local r="$(dirname "$1")/tawcroot"
  mkdir -p "$r" || return 1
  printf '999\n' >"$r/version" || return 1
  echo "已标记 DEGRADED：$r/version=999（不再改写 rootfs 里的硬链接名）"
}

do_prepare() {
  need_tawcroot
  local m=${1:-shared}
  mkdir -p "$WS"
  case "$m" in
    shared)
      [ -d "$SRC_ROOTFS" ] || { echo "找不到 proot rootfs: $SRC_ROOTFS"; exit 3; }
      echo "模式：shared（不复制 rootfs，用 DEGRADED 保护原树）"
      mark_degraded "$SRC_ROOTFS" || { echo "写 DEGRADED 标记失败"; exit 3; }
      echo "shared" >"$MODE_FILE"
      ;;
    copy)
      echo "模式：copy（复制专用 rootfs，约 8GB）"
      if [ -d "$COPY_ROOTFS" ]; then
        echo "已存在 $COPY_ROOTFS（跳过复制）"
      else
        local avail need
        avail=$(df -k "$HOME" | awk 'NR==2{print $4}')
        need=$(du -sk "$SRC_ROOTFS" 2>/dev/null | awk '{print $1}')
        echo "需要约 $((need/1024/1024))GB，$HOME 剩余 $((avail/1024/1024))GB"
        [ "$avail" -gt $((need + 512*1024)) ] || { echo "空间不足"; exit 3; }
        mkdir -p "$COPY_ROOTFS"
        cp -a "$SRC_ROOTFS/." "$COPY_ROOTFS/" || { echo "复制失败"; exit 3; }
      fi
      # copy 模式保留完整 linkstore；但若曾被标记过就清掉标记
      rm -f "$(STORE_OF "$COPY_ROOTFS")/version" 2>/dev/null
      echo "copy" >"$MODE_FILE"
      ;;
    *) echo "usage: $0 prepare [shared|copy]"; exit 2 ;;
  esac

  local dst; dst=$(rootfs_of_mode)
  mkdir -p "$dst/usr/local/bin" "$dst/run/user/0"
  chmod 700 "$dst/run/user/0" 2>/dev/null
  if [ -f "$BOOT_SRC" ]; then
    install -m 755 "$BOOT_SRC" "$dst/usr/local/bin/yoga-plasma-boot"
    echo "已装 $dst/usr/local/bin/yoga-plasma-boot"
  else
    echo "警告：找不到 $BOOT_SRC"
  fi
  echo "prepare done（模式 $(mode)）。起会话前请先停掉 proot 版：pkill -f 'proot-distro login'"
}

do_start() {
  need_tawcroot
  local dst; dst=$(rootfs_of_mode)
  [ -d "$dst" ] || { echo "先跑 yoga-plasma-tawc.sh prepare"; exit 3; }
  if [ "$(mode)" = "shared" ] && [ ! -f "$(STORE_OF "$dst")/version" ]; then
    echo "警告：shared 模式但没找到 DEGRADED 标记 —— 会改写 rootfs！先跑 prepare shared"
    exit 3
  fi

  if ! pgrep -f "bin/anland" >/dev/null 2>&1; then
    rm -f "$TMPDIR/anland/display_daemon.sock" 2>/dev/null
    setsid nohup "$PREFIX/bin/anland" >>"$HOME/wl_stage/anland_daemon.log" 2>&1 &
    for i in $(seq 1 20); do [ -S "$TMPDIR/anland/display_daemon.sock" ] && break; sleep 0.5; done
  fi
  pgrep -f "termux-va-start" >/dev/null 2>&1 || setsid nohup "$PREFIX/bin/termux-va-start" >>"$HOME/wl_stage/termuxva.log" 2>&1 &

  cd "$dst/root" || exit 3
  log "start: mode=$(mode) rootfs=$dst"
  setsid nohup "$PREFIX/bin/tawcroot" -s \
    -r "$dst" \
    -b /dev:/dev \
    -b /proc:/proc \
    -b /sys:/sys \
    -b "$TMP_BIND:/tmp" \
    -- /usr/bin/env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
       TMPDIR=/tmp LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 \
       /bin/bash /usr/local/bin/yoga-plasma-boot \
    >>"$LOG" 2>&1 &
  echo "已发起（日志 $LOG）"
  for i in $(seq 1 45); do
    k=$(cnt_comm kwin_wayland)
    [ "$k" -ge 1 ] && { echo "kwin_wayland=1（约 $((i*2))s）"; break; }
    sleep 2
  done
  echo "kwin=$(cnt_comm kwin_wayland) plasmashell=$(cnt_comm plasmashell)"
}

do_stop() {
  log "stop requested"
  for n in plasmashell kwin_wayland kwin_wayland_wrapper Xwayland startplasma-wayland maliit-keyboard; do
    for p in /proc/[0-9]*/comm; do
      c=$(cat "$p" 2>/dev/null); [ "$c" = "$n" ] || continue
      pid=${p#/proc/}; kill -9 "${pid%/comm}" 2>/dev/null
    done
  done
  for p in /proc/[0-9]*/cmdline; do
    c=$(tr '\0' ' ' <"$p" 2>/dev/null)
    case "$c" in *"bin/tawcroot"*|*"yoga-plasma-boot"*) pid=${p#/proc/}; kill -9 "${pid%/cmdline}" 2>/dev/null ;; esac
  done
  rm -f "$TMPDIR/anland/display_daemon.sock" 2>/dev/null
  echo "已停止（kwin=$(cnt_comm kwin_wayland)）"
}

kwin_jiffies_10s() {
  local pid="" p c
  for p in /proc/[0-9]*/comm; do
    c=$(cat "$p" 2>/dev/null); [ "$c" = kwin_wayland ] || continue
    pid=${p#/proc/}; pid=${pid%/comm}; break
  done
  [ -z "$pid" ] && { echo "kwin 未运行"; return 1; }
  local a b
  a=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null); sleep 10
  b=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)
  echo "kwin jiffies/10s = $((b - a))  (pid=$pid；门控基线：60Hz 124 / 120Hz 211；proot 版当前 293–303)"
}

do_status() {
  local dst; dst=$(rootfs_of_mode)
  echo "模式    : $(mode || echo '(未 prepare)')"
  echo "rootfs  : $dst"
  echo "store   : $(STORE_OF "$dst")/version = $(cat "$(STORE_OF "$dst")/version" 2>/dev/null || echo none)"
  echo "tawcroot: $([ -x "$PREFIX/bin/tawcroot" ] && echo ok || echo missing)"
  echo "会话    : kwin=$(cnt_comm kwin_wayland) plasmashell=$(cnt_comm plasmashell)"
  echo "anland  : $([ -S "$TMPDIR/anland/display_daemon.sock" ] && echo present || echo missing)"
  tail -3 "$LOG" 2>/dev/null
}

case "${1:-status}" in
  prepare) do_prepare "${2:-shared}" ;;
  start) do_start ;;
  stop) do_stop ;;
  status) do_status ;;
  bench) kwin_jiffies_10s ;;
  *) echo "usage: $0 {prepare [shared|copy]|start|stop|status|bench}"; exit 2 ;;
esac
