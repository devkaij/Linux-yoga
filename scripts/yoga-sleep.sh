#!/data/data/com.termux/files/usr/bin/bash
# yoga-sleep.sh —— Linux 会话「睡眠」（像合盖一样：停渲染、屏幕黑、进程保留）
#
# 和 yoga-freeze.sh 的区别：
#   freeze = SIGSTOP 整树（硬冻，CPU 归零，可能 ANR / DBus 超时）
#   sleep  = 软睡眠：停 kwin 合成 + 关 DPMS 输出，进程照常调度但基本不干活，恢复最平滑
#            （可选 --deep 在软睡眠之后再叠 SIGSTOP，兼顾省电）
#
# 用法：
#   yoga-sleep.sh probe         # 探测本机支持哪些睡眠/唤醒通道（先跑这个）
#   yoga-sleep.sh sleep         # 软睡眠
#   yoga-sleep.sh sleep --deep  # 软睡眠 + 5 秒后 SIGSTOP 整树（更省电，唤醒会慢 1–2 秒）
#   yoga-sleep.sh wake          # 唤醒（自动判断要 CONT / resume / dpms on）
#   yoga-sleep.sh status
set -u

PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
export PREFIX
export HOME=${HOME:-/data/data/com.termux/files/home}
export TMPDIR=${TMPDIR:-$PREFIX/tmp}
export PATH=$PREFIX/bin:/system/bin:$PATH
STATE=$TMPDIR/yoga-sleep.state
LOG=$HOME/wl_stage/yoga-sleep.log

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

# 在容器会话里跑一段 bash（自动注入 XDG_RUNTIME_DIR / DBUS 地址 / kgsl 环境）
in_session() {
  $PREFIX/bin/proot-distro login debian-anland --shared-tmp -- /usr/bin/env -i \
    HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TMPDIR=/tmp LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    ANLAND_NO_DRM_DEVICE=1 EGL_PLATFORM=surfaceless \
    MESA_LOADER_DRIVER_OVERRIDE=kgsl TURNIP_KMD=kgsl GALLIUM_DRIVER=freedreno FD_FORCE_KGSL=1 \
    /bin/bash -c '
      export XDG_RUNTIME_DIR=/run/user/0
      K=$(pgrep -x kwin_wayland | head -1)
      if [ -z "$K" ]; then echo "ERR no kwin"; exit 3; fi
      export DBUS_SESSION_BUS_ADDRESS=$(tr "\0" "\n" < /proc/$K/environ | sed -n "s/^DBUS_SESSION_BUS_ADDRESS=//p")
      export WAYLAND_DISPLAY=$(tr "\0" "\n" < /proc/$K/environ | sed -n "s/^WAYLAND_DISPLAY=//p")
      export DISPLAY=$(tr "\0" "\n" < /proc/$K/environ | sed -n "s/^DISPLAY=//p")
      export XAUTHORITY=$(tr "\0" "\n" < /proc/$K/environ | sed -n "s/^XAUTHORITY=//p")
      [ -n "$XAUTHORITY" ] || export XAUTHORITY=$(ls -t /run/user/0/xauth_* 2>/dev/null | head -1)
      '"$1"'
    '
}

# 收集 Linux 会话进程树（供 --deep 用）
collect_tree() {
  local roots="" p c pid ppid
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ -r "$p/cmdline" ] || continue
    c=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)
    case "$c" in
      *"proot-distro login"*|*"/bin/proot "*|*"bin/anland "*|*"termux-va-start"*) roots="$roots $pid" ;;
    esac
  done
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

# ---- 通道探测
probe() {
  echo "== kscreen-doctor --dpms 支持 =="
  in_session 'command -v kscreen-doctor >/dev/null && (kscreen-doctor --help 2>&1 | grep -q -- "--dpms" && echo "DPMS: supported" || echo "DPMS: NOT in --help") || echo "kscreen-doctor: missing"'
  echo
  echo "== KWin 合成器 D-Bus =="
  in_session 'qdbus6 org.kde.KWin /Compositor 2>&1 | head -20'
  echo
  echo "== KWin DPMS D-Bus（若有）=="
  in_session 'qdbus6 org.kde.KWin /DPMS 2>&1 | head -10; qdbus6 org.kde.KWin /PowerManagement 2>&1 | head -10'
}

# ---- 睡眠
do_sleep() {
  local deep=${1:-}
  local rc_dpms rc_comp
  # 1) 关输出（DPMS off）——最像合盖
  out=$(in_session 'kscreen-doctor --dpms off 2>&1 | tail -2; echo "rc=$?"')
  echo "dpms off -> $out"; log "dpms off: $out"
  # 2) 停合成（kwin 不再渲帧 → GPU 空闲）
  out2=$(in_session 'qdbus6 org.kde.KWin /Compositor org.kde.kwin.Compositing.suspend 2>&1 | tail -1; echo "rc=$?"')
  echo "compositing suspend -> $out2"; log "compositing suspend: $out2"
  # 3) 可选：叠 SIGSTOP（更省电，唤醒略慢）
  if [ "$deep" = "--deep" ]; then
    sleep 5
    n=0
    for pid in $(collect_tree); do
      [ "$pid" = "$$" ] && continue
      kill -STOP "$pid" 2>/dev/null && n=$((n+1))
    done
    echo "deep: stopped $n procs"
    log "deep stop: $n"
    printf 'deep\n' >"$STATE"
  else
    printf 'soft\n' >"$STATE"
  fi
  echo "已睡眠（软=${deep:-soft}）。唤醒：yoga-sleep.sh wake"
}

# ---- 唤醒
do_wake() {
  local mode=soft
  [ -f "$STATE" ] && mode=$(cat "$STATE")
  # 1) 若是 deep，先 CONT
  if [ "$mode" = "deep" ]; then
    n=0
    for pid in $(collect_tree); do
      kill -CONT "$pid" 2>/dev/null && n=$((n+1))
    done
    echo "deep: continued $n procs"
    sleep 1
  fi
  # 2) 恢复合成
  out=$(in_session 'qdbus6 org.kde.KWin /Compositor org.kde.kwin.Compositing.resume 2>&1 | tail -1; echo "rc=$?"')
  echo "compositing resume -> $out"; log "compositing resume: $out"
  # 3) 开输出
  out2=$(in_session 'kscreen-doctor --dpms on 2>&1 | tail -2; echo "rc=$?"')
  echo "dpms on -> $out2"; log "dpms on: $out2"
  rm -f "$STATE"
  echo "已唤醒。若画面不刷新：在容器里 qdbus6 org.kde.KWin /KWin reconfigure，或跑 stack-up.sh 重建。"
}

do_status() {
  [ -f "$STATE" ] && echo "记录状态：$(cat "$STATE")" || echo "记录状态：未睡眠"
  in_session 'qdbus6 org.kde.KWin /Compositor org.kde.kwin.Compositing.active 2>/dev/null | sed "s/^/compositing.active = /"'
  t=0; for p in /proc/[0-9]*/stat; do s=$(awk '{print $3}' "$p" 2>/dev/null); [ "$s" = "T" ] && t=$((t+1)); done
  echo "stopped(T) 进程数: $t"
}

case "${1:-status}" in
  probe) probe ;;
  sleep) shift; do_sleep "${1:-}" ;;
  wake) do_wake ;;
  status) do_status ;;
  *) echo "usage: $0 {probe|sleep [--deep]|wake|status}"; exit 2 ;;
esac
