# Linux-yoga · kwin 云端编译

把「带 anland 后端 + 平板笔 + damage 门控 + TabletMode 运行时切换」的 KWin 6.3.6 放到 GitHub Actions 的 **arm64 运行器**上编译，产物只有两个文件，下载后 `adb push` 覆盖即可。

- 目标 ABI：**Debian 13 trixie / aarch64**（必须与容器 rootfs 一致，否则 glibc/Qt 版本对不上）
- 产物：`libkwin.so.6.3.6`（约 44 MB）、`kwin_wayland`（约 7 MB）
- 编译耗时：arm64 原生 runner 约 30–50 分钟；x86 + qemu 约 3–6 小时
- 设备零占用、零发热

## 目录结构

```
Dockerfile                     # debian:trixie + build-dep kwin + ccache
scripts/build.sh               # 取源码 → 打补丁 → 覆盖 → cmake → make → 收产物
scripts/yoga-tabletmode-patch.py   # TabletModeManager 运行时切换（setTabletMode D-Bus slot）
patches/lfdevs/                # lfdevs/kwin debian/trixie 的 debian/patches 全量（含 series）
overlay/                       # 我方改动：src/backends/anland/*（平板笔协议 13–16 + damage 门控）
install-artifact.ps1           # PC 侧：下载的 artifact → 备份 → 覆盖 → ldconfig → 重启 → 可回滚
.github/workflows/build-kwin.yml
```

## 一次性准备

1. 建仓库（**public** 最省事：arm64 托管 runner 对公共仓库免费），把本目录全部文件推上去：

```powershell
cd "D:\AI Desktop\yoga_linux\ghbuild"
git init -b main
git add -A
git -c user.name=devkaij -c user.email=devkaij@users.noreply.github.com commit -m "kwin anland arm64 build pipeline"
git remote add origin https://github.com/<你的账号>/Linux-yoga.git
git push -u origin main
```

2. 打开仓库 → **Actions** → 左侧 `build-kwin-arm64` → `Run workflow`
   - `runner` 选 `ubuntu-24.04-arm`（原生，快）
   - 若提示 arm64 runner 不可用（私有仓库限制），改选 `ubuntu-latest`，会自动装 qemu 模拟（慢但能跑）
3. 跑完在 run 页面底部下载 artifact `kwin-anland-arm64.zip`

## 装机（PC 侧，需要 USB adb 在线）

```powershell
cd "D:\AI Desktop\yoga_linux\ghbuild"
.\install-artifact.ps1 -ArtifactZip "$env:USERPROFILE\Downloads\kwin-anland-arm64.zip"
```

脚本会：解压 → 校验 sha256 → `adb push` → 容器 rootfs 内备份到 `root/kwin_prev_gh`（首次）→ 覆盖 `usr/lib/aarch64-linux-gnu/libkwin.so.6.3.6` 与 `usr/bin/kwin_wayland` → `ldconfig` → 校验 `anland_tablet_feed` / `flushTabletTools` / `setTabletMode` 符号 → 跑 `stack-up.sh` 重启会话。

**回滚**：

```powershell
.\install-artifact.ps1 -Rollback
```

## 改代码后怎么迭代

- 只改 `overlay/` 里的文件（`src/backends/anland/*`）或 `scripts/yoga-tabletmode-patch.py` → push → Actions 自动重跑（ccache 命中后 **5–10 分钟**出产物）
- 想换上游基线：改 `patches/lfdevs/`（现在锁在 `debian/trixie` 分支，KWin 4:6.3.6）
- 想换编译类型：`build.sh` 里 `-DCMAKE_BUILD_TYPE=Release` 可改 `-DCMAKE_BUILD_TYPE=None`（对应官方包口径，`-O2`）

## 已知约束

- `apt-get source kwin` 依赖 trixie 的 deb-src；Dockerfile 已把 `Types: deb` 改成 `deb deb-src`
- kwin 的 `kwin_wayland` 是独立目标，必须单独 `--target kwin_wayland`（`kwin` 目标不含它）
- 改了 `tabletmodemanager.h` 后必须让 `tabletmodemanager.cpp.o` 重编，否则链接期 `undefined reference`——`build.sh` 每次全新构建目录，不受影响
- 平板笔协议、damage 门控、TabletMode 这三处改动全部来自本机实测，仓库里已有成品文件，无需重新推导
