#!/data/data/com.termux/files/usr/bin/bash
# yoga-engine.sh —— 三引擎一键切换（proot / tawcroot / proroot）
#
# 背景：同一份 rootfs、同一个 Anland 显示端、同一套 guest 启动脚本（yoga-plasma-boot），
# 差别只在「用什么把 guest 进程跑起来」。引擎选择写进 $HOME/workstation/engine，
# yoga-guest-exec.sh 与各启动器都读它，所以切引擎不需要改任何别的脚本。
#
# 用法：
#   yoga-engine show                  # 当前引擎 + 会话/资源状态
#   yoga-engine set proot|tawc|proroot
#   yoga-engine switch proot|tawc|proroot   # stop → set → start（一条命令换引擎）
#   yoga-engine start | stop | bench
set -u

P=${PREFIX:-/data/data/com.termux/files/usr}
export PREFIX=$P
export HOME=${HOME:-/data/data/com.termux/files/home}
export TMPDIR=${TMPDIR:-$P/tmp}
export PATH=$P/bin:/system/bin:$PATH

WS=$HOME/workstation
ENGINE_FILE=$WS/engine
ENGINE=$(cat "$ENGINE_FILE" 2>/dev/null | tr -d ' \r\n'); ENGINE=${ENGINE:-proot}
SRC_ROOTFS=$P/var/lib/proot-distro/containers/debian-anland/rootfs
LOG=$HOME/wl_stage/engine.log

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

cnt_comm() {
  local n=0 c pid s
  for p in /proc/[0-9]*/comm; do
    c=$(cat "$p" 2>/dev/null); [ "$c" = "$1" ] || continue
    pid=${p#/proc/}; pid=${pid%/comm}
    s=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null); [ "$s" = "Z" ] && continue
    n=$((n+1))
  done
  echo $n
}

do_set() {
  local e=${1:-}
  case "$e" in proot|tawc|proroot) ;; *) echo "usage: $0 set proot|tawc|proroot" >&2; exit 2 ;; esac
  mkdir -p "$WS"
  printf '%s\n' "$e" >"$ENGINE_FILE"
  log "set engine=$e"
  echo "引擎已登记：$e（$ENGINE_FILE）"
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
    case "$c" in
      *"bin/tawcroot"*|*"yoga-plasma-boot"*|*"proot-distro login"*|*"libproroot.so"*)
        pid=${p#/proc/}; kill -9 "${pid%/cmdline}" 2>/dev/null ;;
    esac
  done
  rm -f "$TMPDIR/anland/display_daemon.sock" 2>/dev/null
  log "stop (engine=$ENGINE)"
  echo "已停止会话（kwin=$(cnt_comm kwin_wayland)）"
}

do_start() {
  case "$ENGINE" in
    proot)
      if [ -x "$P/bin/stack-up.sh" ]; then setsid nohup "$P/bin/stack-up.sh" >>"$HOME/wl_stage/stack-up.log" 2>&1 &
      elif [ -x "$P/bin/hard-restart.sh" ]; then setsid nohup "$P/bin/hard-restart.sh" >>"$HOME/wl_stage/hard-restart.log" 2>&1 &
      else setsid nohup "$P/bin/yoga-plasma" >>"$HOME/wl_stage/plasma-session.log" 2>&1 & fi
      echo "已发起 proot 会话（看 $HOME/wl_stage/*.log）"
      ;;
    tawc)
      exec "$P/bin/yoga-plasma-tawc" start ;;
    proroot)
      exec "$P/bin/yoga-plasma-proroot" start ;;
  esac
}

do_show() {
  local dst mode
  mode=$(cat "$WS/tawc-mode" 2>/dev/null | tr -d ' \r\n')
  dst=$SRC_ROOTFS
  [ "$mode" = "copy" ] && [ -d "$WS/desktop-rootfs" ] && dst=$WS/desktop-rootfs
  echo "引擎   : $ENGINE"
  echo "模式   : ${mode:-(未 prepare)}"
  echo "rootfs : $dst $([ -d "$dst" ] && echo "(ok)" || echo "(缺失)")"
  echo "二进制 : tawcroot=$([ -x "$P/bin/tawcroot" ] && echo ok || echo missing)  proroot=$([ -x "$P/opt/proroot/libproroot.so" ] && echo ok || echo missing)"
  echo "会话   : kwin=$(cnt_comm kwin_wayland) plasmashell=$(cnt_comm plasmashell)"
  echo "wayland: $([ -S "$dst/run/user/0/wayland-0" ] && echo present || echo missing)"
  echo "anland : $([ -S "$TMPDIR/anland/display_daemon.sock" ] && echo present || echo missing)"
  echo "router : $(pgrep -f yoga-mode-router >/dev/null 2>&1 && echo running || echo stopped)"
  local hz; hz=$(dumpsys display 2>/dev/null | grep -o 'fps=[0-9.]*' | head -1)
  echo "刷新率 : ${hz:-?}  电池: $(dumpsys battery 2>/dev/null | sed -n 's/.*level: //p' | head -1)%"
}

do_bench() {
  local pid="" p c a b
  for p in /proc/[0-9]*/comm; do
    c=$(cat "$p" 2>/dev/null); [ "$c" = kwin_wayland ] || continue
    pid=${p#/proc/}; pid=${pid%/comm}; break
  done
  [ -z "$pid" ] && { echo "kwin 未运行"; return 1; }
  a=$(awk '{print $14+$15}' "/proc/$pid/stat"); sleep 10
  b=$(awk '{print $14+$15}' "/proc/$pid/stat")
  echo "engine=$ENGINE  kwin jiffies/10s = $((b-a))  (proot 基线 293–303；目标 ≤150)"
  log "bench engine=$ENGINE jiffies=$((b-a))"
}

case "${1:-show}" in
  show) do_show ;;
  set) shift; do_set "${1:-}" ;;
  start) do_start ;;
  stop) do_stop ;;
  bench) do_bench ;;
  switch) shift; do_stop; do_set "${1:-}"; do_start ;;
  *) echo "usage: $0 {show|set <proot|tawc|proroot>|start|stop|bench|switch <engine>}"; exit 2 ;;
esac
