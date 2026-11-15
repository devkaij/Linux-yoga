#!/data/data/com.termux/files/usr/bin/bash
# yoga-freeze.sh —— Linux 会话「冻结/解冻」（不杀进程、内存保留、CPU 归零）
#
# 原理：对整棵 Linux 会话进程树发 SIGSTOP（内核不再调度 → CPU 0%），
#       解冻用 SIGCONT。安卓应用进程（Termux/Anland UI）不动，所以还能点图标解冻。
#
# 用法：
#   yoga-freeze.sh freeze     # 冻结（≈0% CPU）
#   yoga-freeze.sh unfreeze   # 解冻
#   yoga-freeze.sh status     # 看有多少进程处于 T(stopped) 状态
#
# 注意：
# - SIGSTOP 不回收内存，RSS 仍在（Android 没有可用的 swap 控制权，无 root 做不到换出）。
# - 解冻后 kwin/DBus 可能有超时噪声；若画面不刷新，用 stack-up.sh 重建。
set -u

PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
export PREFIX
export HOME=${HOME:-/data/data/com.termux/files/home}
export TMPDIR=${TMPDIR:-$PREFIX/tmp}
export PATH=$PREFIX/bin:/system/bin:$PATH
STATE=$TMPDIR/yoga-freeze.state
LOG=$HOME/wl_stage/yoga-freeze.log

UID_ME=$(id -u)

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

# 收集「Linux 会话」的所有 pid：
#   1) proot 及其全部后代
#   2) anland 守护进程、termux-va（按 cmdline 匹配）
#   3) 容器内桌面进程（kwin_wayland/plasmashell/Xwayland，PROOT 子进程，通常已含在 1 里）
collect_tree() {
  local roots="" p c ppid
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ -r "$p/cmdline" ] || continue
    c=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)
    case "$c" in
      *"proot-distro login"*|*"/bin/proot "*|*"/usr/bin/anland"*|*"termux-va-start"*|*"bin/anland "*)
        roots="$roots $pid" ;;
    esac
  done
  # 展开后代（BFS）
  local all="$roots" frontier="$roots"
  while [ -n "$(echo $frontier)" ]; do
    local next=""
    for p in /proc/[0-9]*; do
      pid=${p#/proc/}
      [ -r "$p/stat" ] || continue
      ppid=$(awk '{print $4}' "$p/stat" 2>/dev/null)
      case " $frontier " in
        *" $ppid "*) case " $all " in *" $pid "*) ;; *) all="$all $pid"; next="$next $pid" ;; esac ;;
      esac
    done
    frontier=$next
  done
  echo $all
}

do_freeze() {
  local pids n=0
  pids=$(collect_tree)
  [ -z "$(echo $pids)" ] && { echo "没有找到 Linux 会话进程（先起桌面）"; exit 3; }
  for pid in $pids; do
    [ "$pid" = "$$" ] && continue
    kill -STOP "$pid" 2>/dev/null && n=$((n+1))
  done
  echo "$(date +%s)" >"$STATE"
  log "freeze: stopped=$n"
  echo "已冻结 $n 个进程（CPU 归零，内存保留）。解冻：yoga-freeze.sh unfreeze"
}

do_unfreeze() {
  local pids n=0
  pids=$(collect_tree)
  for pid in $pids; do
    kill -CONT "$pid" 2>/dev/null && n=$((n+1))
  done
  rm -f "$STATE"
  log "unfreeze: continued=$n"
  echo "已解冻 $n 个进程。若画面不刷新，运行 stack-up.sh 重建会话。"
}

do_status() {
  local t=0 total=0 p
  for p in /proc/[0-9]*; do
    [ -r "$p/stat" ] || continue
    s=$(awk '{print $3}' "$p/stat" 2>/dev/null)
    [ "$s" = "T" ] && t=$((t+1))
    total=$((total+1))
  done
  echo "系统内 stopped(T) 进程数: $t / $total"
  if [ -f "$STATE" ]; then
    echo "本脚本记录：已冻结（自 $(date -d @"$(cat "$STATE")" '+%F %T' 2>/dev/null || cat "$STATE")）"
  else
    echo "本脚本记录：未冻结"
  fi
}

case "${1:-status}" in
  freeze) do_freeze ;;
  unfreeze) do_unfreeze ;;
  status) do_status ;;
  *) echo "usage: $0 {freeze|unfreeze|status}"; exit 2 ;;
esac
