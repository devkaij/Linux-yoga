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
  mkdir -p "$HOME/wl_stage"
  echo tawc >"$HOME/workstation/engine" 2>/dev/null || true

  # 1. Anland 显示守护进程
  if ! pgrep -f "bin/anland" >/dev/null 2>&1; then
    rm -f "$TMPDIR/anland/display_daemon.sock" 2>/dev/null
    setsid nohup "$PREFIX/bin/anland" >>"$HOME/wl_stage/anland_daemon.log" 2>&1 &
    for i in $(seq 1 20); do [ -S "$TMPDIR/anland/display_daemon.sock" ] && break; sleep 0.5; done
  fi
  [ -S "$TMPDIR/anland/display_daemon.sock" ] || { echo "anland socket 未出现"; exit 3; }

  # 2. Termux:VA（硬解桥，失败不阻塞）
  pgrep -f "termux-va-start" >/dev/null 2>&1 || setsid nohup "$PREFIX/bin/termux-va-start" >>"$HOME/wl_stage/termuxva.log" 2>&1 &

  # 3. Anland App 必须在前台，SurfaceView 才存在（proot 版 stack-up.sh 同样这一步）
  if [ -x "$PREFIX/bin/adb" ]; then
    "$PREFIX/bin/adb" -s 127.0.0.1:5555 shell am start -n com.anland.termux/.MainActivity >/dev/null 2>&1 \
      && echo "已把 Anland App 切到前台" || echo "提示：am start 失败（无线 adb 没连？手动点开 Anland App）"
    sleep 6
  else
    echo "提示：没有 $PREFIX/bin/adb，请手动把 Anland App 切到前台"
  fi

  # 4. 键盘插拔路由 + 笔身手势前台检测（与 proot 版共用，引擎无关）
  for pair in "yoga-mode-router:yoga-mode" "pen-focus-watch:penfocus"; do
    cmd=${pair%%:*}; tag=${pair##*:}
    if command -v "$cmd" >/dev/null 2>&1 && ! pgrep -f "$cmd" >/dev/null 2>&1; then
      setsid nohup "$PREFIX/bin/$cmd" >>"$HOME/wl_stage/$tag.log" 2>&1 &
      echo "已启动 $cmd"
    fi
  done

  # 5. 起会话（tawcroot 新起一个 guest 进程；会话的 socket 落在 rootfs 里，宿主机可直接看）
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

  # 6. 等 kwin + wayland socket（socket 是真实文件：<rootfs>/run/user/0/wayland-0）
  local k s
  for i in $(seq 1 45); do
    k=$(cnt_comm kwin_wayland)
    s=0; [ -S "$dst/run/user/0/wayland-0" ] && s=1
    { [ "$k" -ge 1 ] && [ "$s" -eq 1 ]; } && { echo "kwin_wayland=1 + wayland-0（约 $((i*2))s）"; break; }
    sleep 2
  done
  echo "kwin=$(cnt_comm kwin_wayland) plasmashell=$(cnt_comm plasmashell) sock=$s"

  # 7. plasmashell 没起来就按需手拉（等价 stack-up.sh 的 fallback）
  if [ "$(cnt_comm plasmashell)" -eq 0 ] && [ "$(cnt_comm kwin_wayland)" -ge 1 ]; then
    echo "plasmashell 未起，按 fallback 手拉…"
    setsid nohup "$PREFIX/bin/tawcroot" -s -r "$dst" \
      -b /dev:/dev -b /proc:/proc -b /sys:/sys -b "$TMP_BIND:/tmp" \
      -- /usr/bin/env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
         TMPDIR=/tmp LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 \
         XDG_RUNTIME_DIR=/run/user/0 WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland \
         ANLAND_NO_DRM_DEVICE=1 EGL_PLATFORM=surfaceless MESA_LOADER_DRIVER_OVERRIDE=kgsl \
         TURNIP_KMD=kgsl GALLIUM_DRIVER=freedreno FD_FORCE_KGSL=1 \
         /bin/sh -c 'k=$(pgrep -x kwin_wayland | head -1); [ -n "$k" ] && export DBUS_SESSION_BUS_ADDRESS=$(tr "\0" "\n" < /proc/$k/environ | sed -n "s/^DBUS_SESSION_BUS_ADDRESS=//p" | head -1); exec /usr/bin/plasmashell' \
      >>"$HOME/wl_stage/psh_fallback.log" 2>&1 &
    sleep 12
    echo "fallback 后 plasmashell=$(cnt_comm plasmashell)"
  fi
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
  echo "引擎    : $(cat "$HOME/workstation/engine" 2>/dev/null || echo 'proot(未设置)')  ← 当前登记值"
  echo "模式    : $(mode || echo '(未 prepare)')"
  echo "rootfs  : $dst"
  echo "store   : $(STORE_OF "$dst")/version = $(cat "$(STORE_OF "$dst")/version" 2>/dev/null || echo none)"
  echo "tawcroot: $([ -x "$PREFIX/bin/tawcroot" ] && echo ok || echo missing)"
  echo "会话    : kwin=$(cnt_comm kwin_wayland) plasmashell=$(cnt_comm plasmashell)"
  echo "wayland : $([ -S "$dst/run/user/0/wayland-0" ] && echo present || echo missing)"
  echo "anland  : $([ -S "$TMPDIR/anland/display_daemon.sock" ] && echo present || echo missing)"
  echo "router  : $(pgrep -f yoga-mode-router >/dev/null 2>&1 && echo running || echo stopped)"
  tail -3 "$LOG" 2>/dev/null
}

do_doctor() {
  local ok=0 warn=0 fail=0 dst; dst=$(rootfs_of_mode)
  chk() {
    case "$2" in
      ok)   ok=$((ok+1));   printf '  \033[32m√\033[0m %-24s %s\n' "$1" "$3" ;;
      warn) warn=$((warn+1)); printf '  \033[33m!\033[0m %-24s %s\n' "$1" "$3" ;;
      *)    fail=$((fail+1)); printf '  \033[31m×\033[0m %-24s %s\n' "$1" "$3" ;;
    esac
  }
  echo "== tawcroot 版桌面 · 起飞前检查 =="
  echo "模式=$(mode || echo '(未 prepare)')  rootfs=$dst"

  if [ -x "$PREFIX/bin/tawcroot" ]; then chk "tawcroot 二进制" ok "$PREFIX/bin/tawcroot ($(stat -c %s "$PREFIX/bin/tawcroot" 2>/dev/null)B)"
  else chk "tawcroot 二进制" fail "缺 $PREFIX/bin/tawcroot（需 tawcroot-builder 产物）"; fi

  if [ -d "$dst" ]; then chk "rootfs" ok "$(du -sh "$dst" 2>/dev/null | awk '{print $1}')"
  else chk "rootfs" fail "不存在：$dst（先 prepare）"; fi

  local sv; sv=$(cat "$(STORE_OF "$dst")/version" 2>/dev/null)
  if [ "$(mode)" = "shared" ]; then
    if [ -n "$sv" ]; then chk "DEGRADED 保护" ok "store version=$sv（不改写硬链接名）"
    else chk "DEGRADED 保护" fail "shared 模式缺版本标记 —— 会改写 rootfs！跑 prepare shared"; fi
  else
    chk "DEGRADED 保护" ok "copy 模式（独立 rootfs，不涉及）"
  fi

  if [ -x "$dst/usr/local/bin/yoga-plasma-boot" ]; then chk "guest 启动脚本" ok "/usr/local/bin/yoga-plasma-boot"
  else chk "guest 启动脚本" fail "未装（跑 prepare 会装）"; fi

  command -v inotifywait >/dev/null 2>&1 && chk "inotify-tools" ok "键盘路由可用" \
    || chk "inotify-tools" warn "缺（键盘插拔切换会失效）：pkg install inotify-tools"

  [ -x "$PREFIX/bin/yoga-guest-exec" ] && chk "yoga-guest-exec" ok "引擎无关入口已装" \
    || chk "yoga-guest-exec" warn "未装（键盘切换会退回失败）"
  [ -x "$PREFIX/bin/yoga-mode-router" ] && chk "yoga-mode-router" ok "已装" \
    || chk "yoga-mode-router" warn "未装（插拔键盘不会切形态）"

  if command -v "$PREFIX/bin/adb" >/dev/null 2>&1; then
    if "$PREFIX/bin/adb" -s 127.0.0.1:5555 get-state 2>/dev/null | grep -q device; then
      chk "无线 adb" ok "127.0.0.1:5555 在线（可自动切前台）"
    else chk "无线 adb" warn "未连（start 时需手动点开 Anland App）"; fi
  else chk "无线 adb" warn "未装（同上）"; fi

  [ -S "$TMPDIR/anland/display_daemon.sock" ] && chk "anland socket" ok "present" \
    || chk "anland socket" warn "未起（start 会拉起）"

  local av; av=$(df -k "$HOME" | awk 'NR==2{print int($4/1024/1024)}')
  [ "$av" -ge 2 ] && chk "剩余空间" ok "$av GB" || chk "剩余空间" fail "仅 $av GB"

  echo "== 结论：√$ok  !$warn  ×$fail =="
  [ "$fail" -eq 0 ] && echo "可以起：yoga-plasma-tawc start（先停 proot 版会话）" \
                    || echo "先把 × 项修掉再起。"
}

case "${1:-status}" in
  prepare) do_prepare "${2:-shared}" ;;
  doctor) do_doctor ;;
  start) do_start ;;
  stop) do_stop ;;
  status) do_status ;;
  bench) kwin_jiffies_10s ;;
  *) echo "usage: $0 {prepare [shared|copy]|doctor|start|stop|status|bench}"; exit 2 ;;
esac
