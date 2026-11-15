#!/data/data/com.termux/files/usr/bin/bash
# yoga-plasma-proroot.sh —— 用 proroot（coderredlab/proroot，零 ptrace）跑 Plasma 会话
#
# 与 yoga-plasma-tawc.sh 并列的第三个引擎，用于 A/B 对比：
#   proot（现在在用的，ptrace 每 syscall 两次上下文切换，≈19% 单核税）
#   tawcroot（seccomp 陷阱 + 进程内 SIGSYS，开源，实测 2.75× 编译、8.9× find）
#   proroot（seccomp 陷阱 + LD_PRELOAD 路径钩子 + 私有 cleanroom linker，闭源二进制）
#
# proroot 事实（v1.2.8，2026-06-17，assets 五个 .so，共 ~615KB）：
#   - 只在**路径类** syscall 上打钩子，其余 syscall 直通内核 ⇒ 「zero ptrace」
#   - Termux 里可用（作者自带 termux-full-smoke：40/40，FIELD 含 XFCE+VNC、Playwright
#     Chromium、Node、mesa Turnip KGSL）；**没有 Wayland/Anland 的验证记录**
#   - `--link2symlink` 会把硬链接成员改成 metadata+符号链接 ⇒ **会改写 rootfs 里的名字**，
#     所以默认不开启；只在 copy 模式下才允许（与 tawcroot 的取舍一致）
#   - 闭源、源码未公开、作者主线已转向 proroom（更新会变慢）⇒ 只能当「候选/对照」
#
# 用法：
#   yoga-plasma-proroot.sh install          # 下载 5 个 .so 到 $PREFIX/opt/proroot（校验 sha256）
#   yoga-plasma-proroot.sh start [--copy]   # 起会话（默认用 proot 那份 rootfs，不改写）
#   yoga-plasma-proroot.sh stop | status | bench
set -u

PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
export PREFIX
export HOME=${HOME:-/data/data/com.termux/files/home}
export TMPDIR=${TMPDIR:-$PREFIX/tmp}
export PATH=$PREFIX/bin:/system/bin:$PATH

SRC_ROOTFS=$PREFIX/var/lib/proot-distro/containers/debian-anland/rootfs
WS=$HOME/workstation
COPY_ROOTFS=$WS/desktop-rootfs
DIR=$PREFIX/opt/proroot
LAUNCHER=$DIR/libproroot.so
BOOT=$PREFIX/bin/yoga-plasma-boot.sh
[ -f "$BOOT" ] || BOOT=$HOME/wl_stage/yoga-plasma-boot.sh
LOG=$HOME/wl_stage/proroot-plasma.log
VER=v1.2.8
BASE=https://gh-proxy.com/https://github.com/coderredlab/proroot/releases/download/$VER

# 官方 release notes 给出的 sha256（v1.2.8）
declare -A SHA=(
  [libproroot.so]=a4e74d75b66cdc02b080adfe863dbf9951c3b30610d77beddc95488d5fe5de01
  [libproroot-runtime.so]=8c47a0a7db32d84c179ebb5bf3640f655a3181860ece5886ae44d92858730c34
  [libproroot-bridge.so]=1c5bc9537a270e8bf8b1c70222813f57b60b828bfb5503ddf8fe37685092de2f
  [libproroot-linker.so]=51a0ec5bfed00e572a0de09e22d9057e2befc386b78e426613d3e0ab03f4ecee
  [libproroot-stub-loader.so]=06c6624db3bdc45b9ced151cd781df439a37b47731d244b93e9d6a58cd48cde0
)

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

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

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

do_install() {
  mkdir -p "$DIR"
  local f out got
  for f in "${!SHA[@]}"; do
    out="$DIR/$f"
    if [ -f "$out" ] && [ "$(sha_of "$out")" = "${SHA[$f]}" ]; then
      echo "ok(已存在) $f"
      continue
    fi
    echo "下载 $f …"
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$BASE/$f" -o "$out"
    else wget -qO "$out" "$BASE/$f"; fi
    got=$(sha_of "$out")
    if [ "$got" != "${SHA[$f]}" ]; then
      echo "!! sha256 不符 $f"; echo "   got=$got"; echo "   期望=${SHA[$f]}"; rm -f "$out"; exit 4
    fi
    echo "ok $f ($(stat -c %s "$out" 2>/dev/null || echo ?)B)"
  done
  chmod 755 "$DIR"/libproroot*.so
  echo "装好：$DIR"
}

do_start() {
  [ -x "$LAUNCHER" ] || { echo "先跑: $0 install"; exit 3; }
  local use_copy=0
  [ "${1:-}" = "--copy" ] && use_copy=1
  local rootfs linkflag=()
  if [ "$use_copy" -eq 1 ]; then
    [ -d "$COPY_ROOTFS" ] || { echo "没有 $COPY_ROOTFS（先 yoga-plasma-tawc.sh prepare copy）"; exit 3; }
    rootfs=$COPY_ROOTFS
    linkflag=(--link2symlink)   # 只在副本上才允许改写硬链接名
  else
    rootfs=$SRC_ROOTFS
    [ -d "$rootfs" ] || { echo "找不到 $rootfs"; exit 3; }
  fi

  if ! pgrep -f "bin/anland" >/dev/null 2>&1; then
    rm -f "$TMPDIR/anland/display_daemon.sock" 2>/dev/null
    setsid nohup "$PREFIX/bin/anland" >>"$HOME/wl_stage/anland_daemon.log" 2>&1 &
    for i in $(seq 1 20); do [ -S "$TMPDIR/anland/display_daemon.sock" ] && break; sleep 0.5; done
  fi
  pgrep -f "termux-va-start" >/dev/null 2>&1 || setsid nohup "$PREFIX/bin/termux-va-start" >>"$HOME/wl_stage/termuxva.log" 2>&1 &

  log "start: rootfs=$rootfs link2symlink=$use_copy"
  # proroot 用 $TMPDIR 放运行时配置文件（Termux 里必须可写）
  export PROROOT_TMP_DIR=$TMPDIR
  export PROROOT_VERBOSE=${PROROOT_VERBOSE:-1}
  setsid nohup "$LAUNCHER" \
    -r "$rootfs" -0 -w /root "${linkflag[@]}" \
    -b /dev -b /proc -b /sys -b "$TMPDIR:/tmp" \
    /usr/bin/env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      TMPDIR=/tmp LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 \
      /bin/bash /usr/local/bin/yoga-plasma-boot \
    >>"$LOG" 2>&1 &
  echo "已发起（日志 $LOG）"
  for i in $(seq 1 45); do
    [ "$(cnt_comm kwin_wayland)" -ge 1 ] && { echo "kwin_wayland=1（约 $((i*2))s）"; break; }
    sleep 2
  done
  echo "kwin=$(cnt_comm kwin_wayland) plasmashell=$(cnt_comm plasmashell)"
  tail -5 "$LOG" 2>/dev/null
}

do_stop() {
  for n in plasmashell kwin_wayland kwin_wayland_wrapper Xwayland startplasma-wayland maliit-keyboard; do
    for p in /proc/[0-9]*/comm; do
      c=$(cat "$p" 2>/dev/null); [ "$c" = "$n" ] || continue
      pid=${p#/proc/}; kill -9 "${pid%/comm}" 2>/dev/null
    done
  done
  for p in /proc/[0-9]*/cmdline; do
    c=$(tr '\0' ' ' <"$p" 2>/dev/null)
    case "$c" in *"proroot"*|*"yoga-plasma-boot"*) pid=${p#/proc/}; kill -9 "${pid%/cmdline}" 2>/dev/null ;; esac
  done
  rm -f "$TMPDIR/anland/display_daemon.sock" 2>/dev/null
  echo "已停止（kwin=$(cnt_comm kwin_wayland)）"
}

do_status() {
  echo "assets : $DIR $([ -x "$LAUNCHER" ] && echo ok || echo missing) ($(ls "$DIR" 2>/dev/null | wc -l) files)"
  echo "会话   : kwin=$(cnt_comm kwin_wayland) plasmashell=$(cnt_comm plasmashell)"
  echo "anland : $([ -S "$TMPDIR/anland/display_daemon.sock" ] && echo present || echo missing)"
  echo "proroot 进程: $(for p in /proc/[0-9]*/cmdline; do tr '\0' ' ' <"$p" 2>/dev/null; echo; done | grep -c libproroot)"
  tail -5 "$LOG" 2>/dev/null
}

do_bench() {
  local pid="" p c
  for p in /proc/[0-9]*/comm; do
    c=$(cat "$p" 2>/dev/null); [ "$c" = kwin_wayland ] || continue
    pid=${p#/proc/}; pid=${pid%/comm}; break
  done
  [ -z "$pid" ] && { echo "kwin 未运行"; return 1; }
  local a b
  a=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null); sleep 10
  b=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)
  echo "kwin jiffies/10s = $((b - a))  (基准：proot 293–303 / tawcroot 目标 ≤150)"
}

case "${1:-status}" in
  install) do_install ;;
  start) shift; do_start "$@" ;;
  stop) do_stop ;;
  status) do_status ;;
  bench) do_bench ;;
  *) echo "usage: $0 {install|start [--copy]|stop|status|bench}"; exit 2 ;;
esac
