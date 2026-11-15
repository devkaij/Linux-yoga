#!/data/data/com.termux/files/usr/bin/bash
# install-tawc-desktop.sh —— 一条命令装好「tawcroot 版桌面启动器」
#
# 在 Termux 里跑：
#   curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/devkaij/Linux-yoga/main/termux/install-tawc-desktop.sh | bash
#
# 做的事：把 yoga-plasma-tawc.sh 与 yoga-plasma-boot.sh 装进 $PREFIX/bin（755）。
# 不复制 rootfs、不动现有会话 —— rootfs 副本由 `yoga-plasma-tawc prepare` 在需要时再建。
set -eu

PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
RAW=${YOGA_RAW:-https://gh-proxy.com/https://raw.githubusercontent.com/devkaij/Linux-yoga/main/termux}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  else wget -qO "$2" "$1"; fi
}

echo "== 下载启动器 =="
fetch "$RAW/yoga-plasma-tawc.sh"     "$TMP/yoga-plasma-tawc"
fetch "$RAW/yoga-plasma-boot.sh"     "$TMP/yoga-plasma-boot"
fetch "$RAW/yoga-guest-exec.sh"      "$TMP/yoga-guest-exec"
fetch "$RAW/yoga-engine.sh"          "$TMP/yoga-engine"
install -m 755 "$TMP/yoga-plasma-tawc" "$PREFIX/bin/yoga-plasma-tawc"
install -m 755 "$TMP/yoga-plasma-boot" "$PREFIX/bin/yoga-plasma-boot"
install -m 755 "$TMP/yoga-guest-exec"  "$PREFIX/bin/yoga-guest-exec"
install -m 755 "$TMP/yoga-engine"      "$PREFIX/bin/yoga-engine"
echo "OK: $PREFIX/bin/yoga-plasma-tawc"
echo "    $PREFIX/bin/yoga-plasma-boot"
echo "    $PREFIX/bin/yoga-guest-exec   # 引擎无关的 in-guest 执行入口"
echo "    $PREFIX/bin/yoga-engine       # 三引擎切换 show/set/switch/bench"

if [ ! -x "$PREFIX/bin/tawcroot" ]; then
  echo
  echo "⚠ 还没有 $PREFIX/bin/tawcroot —— 需要先编："
  echo "  git clone --depth 1 https://gh-proxy.com/https://github.com/wmww/tawc \$HOME/tawc && \\"
  echo "  bash \$HOME/tawc/tawcroot/build.sh --abi=aarch64 && \\"
  echo "  install -m 755 \$HOME/tawc/tawcroot/out/aarch64/tawcroot \$PREFIX/bin/tawcroot"
fi

echo
echo "下一步："
echo "  yoga-plasma-tawc doctor     # 体检：二进制/rootfs/DEGRADED/adb/socket 全项"
echo "  yoga-plasma-tawc prepare    # 一次性：默认 shared(DEGRADED)，不复制 8GB"
echo "  yoga-plasma-tawc start      # 起 tawcroot 版桌面"
echo "  yoga-engine bench           # 测 kwin CPU（proot 基线 293–303，目标 ≤150）"
echo
echo "切引擎（任意时刻）："
echo "  yoga-engine show                    # 当前引擎/会话/wayland/socket/刷新率"
echo "  yoga-engine switch tawc             # 停 → 登记 → 起（一条命令换引擎）"
echo "  yoga-engine switch proot            # 回退到 proot（旧的 yoga-plasma/stack-up 链路）"
echo "  yoga-engine switch proroot          # 对照 proroot（需先 yoga-plasma-proroot install）"
echo
echo "proot 版 rootfs 保持原样、不被 tawcroot 改写，随时可回退。"
