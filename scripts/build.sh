#!/usr/bin/env bash
# 在容器里完成：取 kwin 源码 → 打 lfdevs 补丁 → 覆盖我方改动 → 配置 → 编译 → 收产物
# 约定目录（容器内）：
#   /work            = 仓库根（含 patches/ overlay/ scripts/）
#   /work/out        = 产物输出（libkwin.so.6.3.6 / kwin_wayland）
#   /ccache          = ccache 缓存目录
set -euo pipefail

WORK=${WORK:-/work}
OUT="$WORK/out"
SRCROOT="$WORK/src"
JOBS=${JOBS:-$(nproc)}

echo "== [1/6] 准备源码目录 =="
mkdir -p "$SRCROOT" "$OUT"
cd "$SRCROOT"

# deb-src 自愈：镜像层里 /var/lib/apt/lists 被清空过，或 base image 用别的 sources 布局，
# 这里无条件重新确认 deb-src 并 update，避免 "You must put some 'deb-src' URIs"。
ensure_deb_src() {
  local f
  for f in /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list; do
    [ -f "$f" ] || continue
    if grep -qE '^Types:[[:space:]]*deb[[:space:]]*$' "$f"; then
      sed -i -E 's/^Types:[[:space:]]*deb[[:space:]]*$/Types: deb deb-src/' "$f"
    fi
  done
  # deb822 布局没有 Types 行时，追加传统 deb-src 行兜底
  if ! grep -rqE '^(deb-src|Types:.*deb-src)' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    echo "deb-src http://deb.debian.org/debian trixie main contrib non-free non-free-firmware" >> /etc/apt/sources.list
  fi
  echo "--- active deb-src entries ---"
  grep -rhE '^(deb-src|Types:.*deb-src)' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true
}
ensure_deb_src
apt-get update -qq

if ! ls -d kwin-* >/dev/null 2>&1; then
  apt-get source kwin
fi
KSRC=$(echo "$SRCROOT"/kwin-* | awk '{print $1}')
echo "kwin source: $KSRC"

echo "== [2/6] 应用 lfdevs anland 补丁（按 debian/patches/series 顺序）=="
cd "$KSRC"
while read -r p; do
  [ -z "$p" ] && continue
  case "$p" in \#*) continue;; esac
  f="$WORK/patches/lfdevs/$p"
  [ -f "$f" ] || { echo "missing patch: $p"; exit 3; }
  if patch -p1 --forward --silent < "$f"; then
    echo "  applied: $p"
  else
    echo "  FAILED: $p"; exit 4
  fi
done < "$WORK/patches/lfdevs/series"

echo "== [3/6] 覆盖我方改动（平板笔 + damage 门控 + TabletMode 运行时切换）=="
if [ -d "$WORK/overlay" ]; then
  cp -a "$WORK/overlay/." "$KSRC/"
  echo "  overlay copied"
fi
if [ -f "$WORK/scripts/yoga-tabletmode-patch.py" ]; then
  python3 "$WORK/scripts/yoga-tabletmode-patch.py" "$KSRC" && echo "  tabletmode patched"
fi

echo "== [4/6] cmake 配置 =="
BUILD="$WORK/build"
rm -rf "$BUILD"; mkdir -p "$BUILD"
cmake -S "$KSRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_SYSCONFDIR=/etc \
  -DCMAKE_INSTALL_LOCALSTATEDIR=/var \
  -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
  -DBUILD_TESTING=OFF \
  -DQTWAYLANDSCANNER_KDE_EXECUTABLE=/usr/lib/qt6/libexec/qtwaylandscanner \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -G "Unix Makefiles"

echo "== [5/6] 编译 kwin + kwin_wayland（-j$JOBS）=="
cmake --build "$BUILD" --target kwin -j "$JOBS"
cmake --build "$BUILD" --target kwin_wayland -j "$JOBS"

echo "== [6/6] 收产物 =="
LIB=$(find "$BUILD" -name 'libkwin.so.6*' -type f | head -1)
KW=$(find "$BUILD" -name 'kwin_wayland' -type f | head -1)
[ -n "$LIB" ] && [ -n "$KW" ] || { echo "artifact missing"; exit 5; }
cp -f "$LIB" "$OUT/libkwin.so.6.3.6"
cp -f "$KW"  "$OUT/kwin_wayland"
chmod 755 "$OUT"/* 
( cd "$OUT" && sha256sum ./* > SHA256SUMS.txt )
echo "--- artifacts ---"
ls -l "$OUT"
cat "$OUT/SHA256SUMS.txt"
echo "BUILD OK"
