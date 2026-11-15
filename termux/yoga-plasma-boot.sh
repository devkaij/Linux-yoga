#!/bin/bash
# yoga-plasma-boot.sh —— 在 tawcroot 里直接拉起 Plasma（不依赖 sudo / 不用 startplasma-anland）
#
# 放到 tawcroot 专用 rootfs 的 /usr/local/bin/yoga-plasma-boot（755），由 Termux 侧
# yoga-plasma-tawc.sh 调起。语义照抄上游 startplasma-anland 的 container 分支，
# 只把 sudo 去掉（tawcroot 的伪 root 下 sudo 不可靠），并跳过音频（本机 pipewire 已坏）。
set -u

# ---- 环境（与 proot 版等价）
unset DISPLAY SSH_CONNECTION
unset ANLAND_NO_DRM_DEVICE ANLAND_DRM_DEVICE EGL_PLATFORM
unset MESA_LOADER_DRIVER_OVERRIDE TURNIP_KMD GALLIUM_DRIVER FD_FORCE_KGSL XWAYLAND_FORCE_KGSL_SURFACELESS

export QT_QPA_PLATFORM=wayland
export XDG_CURRENT_DESKTOP=KDE
export XDG_SESSION_DESKTOP=KDE
export ANLAND=1
export ANLAND_SOCKET=/tmp/anland/display_daemon.sock
export ANLAND_PIPEWIRE_UNRESTRICTED=1

# 本机事实：/dev/dri 不可读，GPU 走 kgsl；无 DRM 设备 → surfaceless EGL
export ANLAND_NO_DRM_DEVICE=1
export EGL_PLATFORM=surfaceless
export MESA_LOADER_DRIVER_OVERRIDE=kgsl
export TURNIP_KMD=kgsl
export GALLIUM_DRIVER=freedreno
export FD_FORCE_KGSL=1
export XWAYLAND_FORCE_KGSL_SURFACELESS=1

# 自编 5.23-port 后端没有 buffer-age 契约，全量重绘（否则花屏）
export KWIN_USE_BUFFER_AGE=0

export XDG_RUNTIME_DIR=/run/user/0
export LANG=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8
export LANGUAGE=zh_CN:en
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---- 运行时目录
mkdir -p "$XDG_RUNTIME_DIR" /tmp/.X11-unix 2>/dev/null
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
chmod 1777 /tmp/.X11-unix 2>/dev/null
chmod -R 777 /tmp/anland 2>/dev/null || true
rm -f "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null

# ---- 清旧会话（按 comm 精确匹配，避免 pkill -f 误杀自己）
for n in plasmashell kwin_wayland kwin_wayland_wrapper Xwayland startplasma-wayland maliit-keyboard; do
  for p in /proc/[0-9]*/comm; do
    [ "$(cat "$p" 2>/dev/null)" = "$n" ] || continue
    pid=${p#/proc/}; pid=${pid%/comm}
    [ "$pid" = "$$" ] && continue
    kill -9 "$pid" 2>/dev/null
  done
done
sleep 1

# ---- 起会话
echo "[boot] $(date '+%F %T') starting startplasma-wayland (tawcroot)"
exec dbus-run-session -- /usr/bin/startplasma-wayland
