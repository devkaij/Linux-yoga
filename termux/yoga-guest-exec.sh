#!/data/data/com.termux/files/usr/bin/bash
# yoga-guest-exec.sh —— 用「当前引擎」在 guest（Debian 容器）里执行一条命令
#
# 存在的意义：路由器/看护脚本原本写死 `proot-distro login debian-anland --shared-tmp -- …`，
# 一旦换成 tawcroot / proroot，这些调用全都会失败（这两个引擎没有 login 子命令，
# 而是「新起一个 guest 进程」——会话在文件系统里共享 socket，所以照样能进现有会话）。
# 把入口收敛到这里，上层脚本就不用知道引擎是谁。
#
# 用法：
#   yoga-guest-exec.sh <命令…>            # 例：yoga-guest-exec.sh /bin/bash /usr/local/bin/yoga-mode-apply keyboard
#   yoga-guest-exec.sh -q <命令…>         # 静默（不打印引擎横幅）
#
# 引擎选择（优先级从高到低）：
#   $YOGA_ENGINE  →  $HOME/workstation/engine  →  proot
#   取值：proot | tawc | proroot
set -u

P=${PREFIX:-/data/data/com.termux/files/usr}
export PREFIX=$P
export HOME=${HOME:-/data/data/com.termux/files/home}
export TMPDIR=${TMPDIR:-$P/tmp}
export PATH=$P/bin:/system/bin:$PATH

QUIET=0
[ "${1:-}" = "-q" ] && { QUIET=1; shift; }
[ $# -ge 1 ] || { echo "usage: $0 [-q] <cmd...>" >&2; exit 2; }

WS=$HOME/workstation
ENGINE=${YOGA_ENGINE:-$(cat "$WS/engine" 2>/dev/null | tr -d ' \r\n')}
ENGINE=${ENGINE:-proot}

SRC_ROOTFS=$P/var/lib/proot-distro/containers/debian-anland/rootfs
COPY_ROOTFS=$WS/desktop-rootfs
MODE=$(cat "$WS/tawc-mode" 2>/dev/null | tr -d ' \r\n')

say() { [ "$QUIET" -eq 1 ] || echo "yoga-guest-exec[$ENGINE] $*" >&2; }

GUEST_ENV=(/usr/bin/env -i
  HOME=/root
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  TMPDIR=/tmp
  LANG=C.UTF-8
  LC_ALL=C.UTF-8)

case "$ENGINE" in
  proot)
    say "proot-distro login debian-anland --shared-tmp -- $*"
    exec "$P/bin/proot-distro" login debian-anland --shared-tmp -- "${GUEST_ENV[@]}" "$@"
    ;;
  tawc)
    BIN=$P/bin/tawcroot
    [ -x "$BIN" ] || { echo "缺 $BIN（tawcroot 未编）" >&2; exit 3; }
    if [ "$MODE" = "copy" ] && [ -d "$COPY_ROOTFS" ]; then ROOTFS=$COPY_ROOTFS; else ROOTFS=$SRC_ROOTFS; fi
    [ -d "$ROOTFS" ] || { echo "找不到 rootfs: $ROOTFS" >&2; exit 3; }
    say "tawcroot -r $ROOTFS -- $*"
    cd "$ROOTFS/root" 2>/dev/null || cd /
    exec "$BIN" -s -r "$ROOTFS" \
      -b /dev:/dev -b /proc:/proc -b /sys:/sys -b "$TMPDIR:/tmp" \
      -- "${GUEST_ENV[@]}" "$@"
    ;;
  proroot)
    LAUNCHER=$P/opt/proroot/libproroot.so
    [ -x "$LAUNCHER" ] || { echo "缺 $LAUNCHER（先 yoga-plasma-proroot install）" >&2; exit 3; }
    if [ "$MODE" = "copy" ] && [ -d "$COPY_ROOTFS" ]; then ROOTFS=$COPY_ROOTFS; else ROOTFS=$SRC_ROOTFS; fi
    [ -d "$ROOTFS" ] || { echo "找不到 rootfs: $ROOTFS" >&2; exit 3; }
    export PROROOT_TMP_DIR=$TMPDIR
    say "proroot -r $ROOTFS -- $*"
    exec "$LAUNCHER" -r "$ROOTFS" -0 -w /root \
      -b /dev -b /proc -b /sys -b "$TMPDIR:/tmp" \
      -- "${GUEST_ENV[@]}" "$@"
    ;;
  *)
    echo "未知引擎 '$ENGINE'（proot | tawc | proroot）" >&2; exit 2 ;;
esac
