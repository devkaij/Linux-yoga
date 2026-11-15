# tawcroot 版桌面（替换 proot 会话）

状态：**脚本已就绪，待在设备上跑**（写于 2026-11-15，adb 关闭期间准备）。

## 为什么做

现在桌面跑在 `proot-distro login debian-anland --shared-tmp` 里，proot 用 ptrace 拦每个 syscall，
实测代价 **≈19% 单核常驻**（编译类负载更贵）。tawcroot 用 seccomp SIGSYS 在进程内转发，同一棵 kwin 树实测：

| 负载 | proot | tawcroot | 倍数 |
|---|---|---|---|
| kwin 单 TU 编译 (`g++ -O2 -c inputmethod.cpp`) | 12.37s | 4.50s | **2.75×** |
| `find /usr -name '*.h'`（8177 个） | 4.10s | 0.46s | 8.9× |
| `git status` | 0.139s | 0.025s | 5.6× |
| 20 个小编译单元（模拟 make 逐条 exec） | 0.796s | 0.271s | 2.94× |

预期桌面收益：**空转 CPU 19% → 个位数**，应用启动/文件遍历明显变快。这是「应用打开慢、网页加载慢」四层归因里
成本最高、改动最独立的一层（另外三层：全屏合成、浏览器 SHM 拷贝、编译负载本身）。

## 关键设计（为什么不是直接把 proot 换成 tawcroot）

1. **硬链接改写用 DEGRADED 模式规避（默认，不复制 rootfs）**。tawcroot 的硬链接仿真会**就地改写**
   rootfs 里的链接名（改成 `tawcroot:link:<token>` 指向 link store），在 proot 那份上跑会让 proot 看到断链。
   读源码后找到一条不需复制 8GB 的路：`src/linkstore.c` 的 `version_gate()` 在 store 里 `version > 1`
   时把状态置 `DEGRADED`，而 `store_lock()` 对非 `READY` 状态直接返回 `EPERM` ⇒ **所有 store 变更被拒绝、
   文件名不再被改写**，guest 内 `link()` 退回真实 `EPERM`（Android 上本来也是 EPERM，行为反而更真）。
   所以 `prepare shared`（默认）只做两件事：`mkdir <rootfs>/../tawcroot` 并写 `version=999`。
   需要完整硬链接仿真（装 deb、git gc 保真）时才用 `prepare copy`（复制 8.1GB 专用副本）。
2. **不走 `startplasma-anland`**。上游脚本容器分支大量用 `sudo`，tawcroot 的伪 root 下 sudo 不可靠；
   改为 `yoga-plasma-boot.sh` 直接复刻它的语义（环境变量、`/run/user/0`、`/tmp/.X11-unix`、
   `KWIN_USE_BUFFER_AGE=0`、`dbus-run-session -- startplasma-wayland`），跳过音频（本机 pipewire 已坏）。
3. **挂载**：`-b /dev:/dev`（GPU 走 `/dev/kgsl-3d0`；`/dev/dri` 无解，两边都一样）、`-b /proc:/proc`、
   `-b /sys:/sys`、`-b $PREFIX/tmp:/tmp`（anland 与 termux-va 的 socket 都在这儿）。
   `/dev/shm` **不挂**（tawcroot 用 memfd 模拟，跨 execve 保留）。
4. **宿主 cwd 必须在 rootfs 内**（`cd $DST_ROOTFS/root` 再启动），否则 guest `getcwd` 报 ENOENT。
5. **guest 必须清环境**（`/usr/bin/env -i …`），否则 Termux 的 PATH/变量漏进去，会去 `/data/data/com.termux/...` 找 bin。

## 用法（Termux 里）

```bash
# 一次性安装启动器（不需要 adb）
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/devkaij/Linux-yoga/main/termux/install-tawc-desktop.sh | bash

yoga-plasma-tawc status     # 现状：模式、store 标记、tawcroot、会话计数
yoga-plasma-tawc prepare            # 默认 shared：写 DEGRADED 标记，不复制 rootfs
yoga-plasma-tawc prepare copy       # 可选：复制 8.1GB 专用副本，保留完整硬链接仿真
yoga-plasma-tawc start      # 起 anland 守护 + termux-va + tawcroot 会话
yoga-plasma-tawc bench      # kwin jiffies/10s（关键判据）
yoga-plasma-tawc stop       # 停会话
```

前置：`$PREFIX/bin/tawcroot` 存在（`install-tawc-desktop.sh` 会检查并给编译命令）。
**切换前先停止 proot 会话**（否则两套 kwin 抢同一个 `wayland-0`，会花屏/黑屏）：
先 `yoga-plasma-tawc start` 之前跑一次 `pkill -f 'proot-distro login'` 或用 `hard-restart.sh --clean`。

## 验收清单

| 项 | 判据 |
|---|---|
| 会话起来 | `kwin_wayland` 非僵尸计数 = 1，`plasmashell` = 1 |
| 画面正常 | `screencap` > 1.5MB 且非纯黑；无花屏条纹 |
| CPU 收益 | `yoga-plasma-tawc bench` ≤ 150 jiffies/10s（proot 版当前 293–303，门控理想 211） |
| 笔 | 压感笔迹正常、笔身双击 = 右键 |
| 键盘 | 拔插键盘切软键盘（`yoga-mode-router` 仍走 proot 入口，需改成 tawcroot，见下） |
| 音频 | 已知缺失（pipewire 已禁），不作为验收项 |

## 已知风险与处置

| 风险 | 影响 | 处置 |
|---|---|---|
| 硬链接被改写 | 副本 rootfs 一旦被 tawcroot 用过，就不能再给 proot 用 | 只当专用副本；proot 那份不动 |
| `/dev/dri` 不可用 | 与 proot 版现状相同（已走 kgsl + surfaceless） | 无需处理 |
| Qt 的 `/dev/shm` 共享内存 | 某些程序 `ls /dev/shm` 会失败（memfd 模拟无目录项） | 若崩溃改成 `-b /dev/shm:/dev/shm`（风险：跨进程一致性） |
| `sudo`/setuid 不可靠 | 容器内需要 root 的脚本会失败 | 我们的启动路径已不用 sudo |
| 会话生命周期 | tawcroot 是普通进程，宿主 shell 退出会连带 | 已用 `-s`（setsid）+ `setsid nohup` 启动 |
| 双会话抢 `wayland-0` | 花屏/黑屏 | 切换前 `hard-restart.sh --clean`，起来后核对 kwin 计数 = 1 |

## 回退

proot 那份 rootfs 与 `yoga-plasma` / `stack-up.sh` / `hard-restart.sh` **完全没动**。出问题直接：

```bash
yoga-engine switch proot      # 停当前会话 → 登记 proot → 用旧链路起
```

或分步：

```bash
yoga-plasma-tawc stop
bash /data/local/tmp/stack-up.sh        # 起回 proot 版
```

## 切引擎与回滚（`yoga-engine`）

三个引擎跑**同一份 guest 内容**（同一套 `/usr/local/bin/yoga-plasma-boot`、同一 Anland 显示端），差别只在「谁来把 guest 进程跑起来」。
引擎登记在 `$HOME/workstation/engine`，所有启动器与容器入口（`yoga-guest-exec`）都读它。

| 命令 | 作用 |
|---|---|
| `yoga-engine show` | 引擎 / tawc 模式 / rootfs / 二进制 / kwin·plasmashell 计数 / wayland socket / anland socket / router / 刷新率 / 电量 |
| `yoga-engine set proot\|tawc\|proroot` | 只登记，不动会话 |
| `yoga-engine switch <engine>` | 停会话 → 登记 → 起（一条命令换引擎） |
| `yoga-engine start` / `stop` | 按当前引擎起 / 停所有会话 |
| `yoga-engine bench` | kwin `jiffies/10s`（proot 基线 293–303，目标 ≤150） |

`yoga-guest-exec.sh` 是容器入口的统一封装：路由脚本、mode-apply、任何「进容器跑一条命令」的地方都调它，
于是切引擎时**不需要改任何调用方**。

```bash
# proot     → proot-distro login debian-anland --shared-tmp -- env -i …
# tawc      → cd <rootfs>/root && tawcroot -s -r <rootfs> -b /dev:/dev … -- env -i …
# proroot   → libproroot.so -r <rootfs> -0 -w /root -b … -- env -i …
yoga-guest-exec -q /bin/bash /usr/local/bin/yoga-mode-apply hw
```

## 后续（若本轮成功）

1. ~~`yoga-mode-router.sh` 里的容器入口从 `proot-distro login` 换成 `tawcroot`~~ —— 已完成：改为调 `yoga-guest-exec`（引擎无关）。
2. `yoga-heal.sh` / `yoga-sleep.sh` / `switch-bridge` 的容器入口同样切换到 `yoga-guest-exec`（待办）。
3. 若 CPU 收益不如预期，检查是否被 `KWIN_USE_BUFFER_AGE=0`（全量重绘）吃掉 —— 那是花屏的临时解法，
   真修法是后端按 buffer-age 语义清 buffer，属源码级。
