#!/data/data/com.termux/files/usr/bin/bash
# yoga-plasma-tawc.sh —— 用 tawcroot 跑 Plasma 会话（替代 proot-distro login，去掉 ptrace 税）
#
# 为什么单独一份 rootfs：tawcroot 的硬链接仿真会**就地改写** rootfs 里的文件名
# （把 link 名改成 tawcroot:link:<token> 软链），所以不能直接拿 proot 那份跑，
# 否则 proot 会话会看到一堆断链。这里用一份专用副本，proot 那份保持原样可回退。
#
# 用法：
#   yoga-plasma-tawc.sh prepare   # 一次性：复制 rootfs（≈8GB）+ 装入启动脚本
#   yoga-plasma-tawc.sh start     # 起会话（先起 anland 守护与 termux-va）
#   yoga-plasma-tawc.sh stop      # 停会话（不删 rootfs）
#   yoga-plasma-tawc.sh status    # 会话健康 + kwin CPU 采样（10s）
#   yoga-plasma-tawc.sh bench     # 只测 kwin jiffies/10s（跟 proot 版对比用）
#
# 前提：$PREFIX/bin/tawcroot 已装（tawcroot-builder 产物，116,072B ET_EXEC）
set -u

PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
export PREFIX
export HOME=${HOME:-/data/data/com.termux/files/home}
export TMPDIR=${TMPDIR:-$PREFIX/tmp}
export PATH=$PREFIX/bin:/system/bin:$PATH

SRC_ROOTFS=$PREFIX/var/lib/proot-distro/containers/debian-anland/rootfs
WS=$HOME/workstation
DST_ROOTFS=$WS/desktop-rootfs
BOOT_SRC=${YOGA_BOOT_SRC:-$PREFIX/bin/yoga-plasma-boot.sh}
[ -f "$BOOT_SRC" ] || BOOT_SRC=$HOME/wl_stage/yoga-plasma-boot.sh
LOG=$HOME/wl_stage/tawc-plasma.log
TMP_BIND=$TMPDIR

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

need_tawcroot() {
  [ -x "$PREFIX/bin/tawcroot" ] || { echo "缺 $PREFIX/bin/tawcroot（先跑 tawcroot-builder 的编译产物）"; exit 3; }
}

hw_kbd_state() { cat "$TMPDIR/hwkbd.state" 2>/dev/null || echo "?"; }

# 数「非僵尸」的进程数
cnt_comm() {
  local n=0 c pid s
  for p in /proc/[0-9]*/comm; do
    c=$(cat "$p" 2>/dev/null)
    [ "$c" = "$1" ] || continue
    pid=${p#/proc/}; pid=${pid%/comm}
    s=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
    [ "$s" = "Z" ] && continue
    n=$((n+1))
  done
  echo $n
}

do_prepare() {
  need_tawcroot
  if [ -d "$DST_ROOTFS" ]; then
    echo "已存在专用 rootfs：$DST_ROOTFS（跳过复制）"
  else
    [ -d "$SRC_ROOTFS" ] || { echo "找不到 proot rootfs: $SRC_ROOTFS"; exit 3; }
    avail=$(df -k "$HOME" | awk 'NR==2{print $4}')
    need=$(du -sk "$SRC_ROOTFS" 2>/dev/null | awk '{print $1}')
    echo "复制 rootfs：$((need/1024/1024))GB（$HOME 剩余 $((avail/1024/1024))GB）"
    [ "$avail" -gt $((need + 512*1024)) ] || { echo "空间不足（需 > rootfs+512MB）"; exit 3; }
    mkdir -p "$WS"
    mkdir -p "$DST_ROOTFS"
    cp -a "$SRC_ROOTFS/." "$DST_ROOTFS/" || { echo "复制失败"; exit 3; }
    echo "rootfs 复制完成"
  fi

  # 装启动脚本（每次 prepare 都刷新，便于迭代）
  mkdir -p "$DST_ROOTFS/usr/local/bin"
  if [ -f "$BOOT_SRC" ]; then
    install -m 755 "$BOOT_SRC" "$DST_ROOTFS/usr/local/bin/yoga-plasma-boot"
    echo "已装 $DST_ROOTFS/usr/local/bin/yoga-plasma-boot"
  else
    echo "警告：找不到 $BOOT_SRC（启动脚本没装进去）"
  fi
  # /run/user/0 必须是真实可写目录（tawcroot 不挂 tmpfs）
  mkdir -p "$DST_ROOTFS/run/user/0"
  chmod 700 "$DST_ROOTFS/run/user/0" 2>/dev/null
  echo "prepare done。下一步：yoga-plasma-tawc.sh start"
}

do_start() {
  need_tawcroot
  [ -d "$DST_ROOTFS" ] || { echo "先跑 yoga-plasma-tawc.sh prepare"; exit 3; }

  # 1) anland 守护 + termux-va（Termux 侧，不变）
  if ! pgrep -f "bin/anland" >/dev/null 2>&1; then
    rm -f "$TMPDIR/anland/display_daemon.sock" 2>/dev/null
    setsid nohup "$PREFIX/bin/anland" >>"$HOME/wl_stage/anland_daemon.log" 2>&1 &
    for i in $(seq 1 20); do [ -S "$TMPDIR/anland/display_daemon.sock" ] && break; sleep 0.5; done
  fi
  pgrep -f "termux-va-start" >/dev/null 2>&1 || setsid nohup "$PREFIX/bin/termux-va-start" >>"$HOME/wl_stage/termuxva.log" 2>&1 &

  # 2) tawcroot 起会话（宿主 cwd 必须在 rootfs 内，否则 guest getcwd ENOENT）
  cd "$DST_ROOTFS/root" || exit 3
  log "start: tawcroot -r $DST_ROOTFS"
  setsid nohup "$PREFIX/bin/tawcroot" -s \
    -r "$DST_ROOTFS" \
    -b /dev:/dev \
    -b /proc:/proc \
    -b /sys:/sys \
    -b "$TMP_BIND:/tmp" \
    -- /usr/bin/env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
       TMPDIR=/tmp LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 \
       /bin/bash /usr/local/bin/yoga-plasma-boot \
    >>"$LOG" 2>&1 &
  echo "已发起（日志 $LOG）。等待 kwin 起来…"
  for i in $(seq 1 60); do
    k=$(cnt_comm kwin_wayland)
    [ "$k" -ge 1 ] && [ -S "$PREFIX/tmp/anland/display_daemon.sock" ] && { echo "kwin_wayland=1（第 $((i*2))s）"; break; }
    sleep 2
  done
  echo "kwin=$(cnt_comm kwin_wayland) plasmashell=$(cnt_comm plasmashell) hw_kbd=$(hw_kbd_state)"
}

do_stop() {
  log "stop requested"
  for n in plasmashell kwin_wayland kwin_wayland_wrapper Xwayland startplasma-wayland maliit-keyboard; do
    for p in /proc/[0-9]*/comm; do
      c=$(cat "$p" 2>/dev/null); [ "$c" = "$n" ] || continue
      pid=${p#/proc/}; pid=${pid%/comm}
      kill -9 "$pid" 2>/dev/null
    done
  done
  # tawcroot 自身与 guest 的 bash
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
  a=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)
  sleep 10
  b=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)
  echo "kwin jiffies/10s = $((b - a))  (pid=$pid, 120Hz 门控基线 211 / 60Hz 门控 124)"
}

do_status() {
  echo "rootfs  : $DST_ROOTFS $([ -d "$DST_ROOTFS" ] && du -sh "$DST_ROOTFS" 2>/dev/null | awk '{print $1}' || echo '(未准备)')"
  echo "tawcroot: $([ -x "$PREFIX/bin/tawcroot" ] && echo ok || echo missing)"
  echo "kwin=$(cnt_comm kwin_wayland) plasmashell=$(cnt_comm plasmashell) hw_kbd=$(hw_kbd_state)"
  echo "anland sock: $([ -S "$TMPDIR/anland/display_daemon.sock" ] && echo present || echo missing)"
  echo "--- 日志尾 ---"; tail -5 "$LOG" 2>/dev/null
}

case "${1:-status}" in
  prepare) do_prepare ;;
  start) do_start ;;
  stop) do_stop ;;
  status) do_status ;;
  bench) kwin_jiffies_10s ;;
  *) echo "usage: $0 {prepare|start|stop|status|bench}"; exit 2 ;;
esac
