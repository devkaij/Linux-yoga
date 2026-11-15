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
fetch "$RAW/yoga-plasma-tawc.sh" "$TMP/yoga-plasma-tawc"
fetch "$RAW/yoga-plasma-boot.sh" "$TMP/yoga-plasma-boot"
install -m 755 "$TMP/yoga-plasma-tawc" "$PREFIX/bin/yoga-plasma-tawc"
install -m 755 "$TMP/yoga-plasma-boot" "$PREFIX/bin/yoga-plasma-boot"
echo "OK: $PREFIX/bin/yoga-plasma-tawc"
echo "    $PREFIX/bin/yoga-plasma-boot"

if [ ! -x "$PREFIX/bin/tawcroot" ]; then
  echo
  echo "⚠ 还没有 $PREFIX/bin/tawcroot —— 需要先编："
  echo "  git clone --depth 1 https://gh-proxy.com/https://github.com/wmww/tawc \$HOME/tawc && \\"
  echo "  bash \$HOME/tawc/tawcroot/build.sh --abi=aarch64 && \\"
  echo "  install -m 755 \$HOME/tawc/tawcroot/out/aarch64/tawcroot \$PREFIX/bin/tawcroot"
fi

echo
echo "下一步："
echo "  yoga-plasma-tawc status     # 看现状"
echo "  yoga-plasma-tawc prepare    # 一次性：建专用 rootfs 副本（约 8GB，需几分钟）"
echo "  yoga-plasma-tawc start      # 起 tawcroot 版桌面"
echo "  yoga-plasma-tawc bench      # 测 kwin CPU（对比 proot 版）"
echo "proot 版会话不受影响，随时用旧的 yoga-plasma / stack-up.sh 回退。"
