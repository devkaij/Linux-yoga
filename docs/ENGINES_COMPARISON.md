# 三种 rootless 引擎对比：proot / tawcroot / proroot

写于 2026-11-15。目标：给 TB520FU 上的 Plasma 桌面挑「CPU 税最低、还不把功能搞坏」的那一个。

## 一句话结论

- **proot**：稳、开源、社区成熟；代价是 ptrace 拦每个 syscall，桌面常驻 **≈19% 单核**。
- **tawcroot**：开源、行为最接近内核（seccomp 陷阱 + 进程内 SIGSYS），实测比 proot 快 2.75%（编译）/8.9×（文件遍历）；要规避硬链接改写，需 DEGRADED 标记或用副本。
- **proroot**：闭源二进制，同样零 ptrace，但走的是**路径钩子（LD_PRELOAD 类）+ 私有 cleanroom linker**；作者自测覆盖 Node/Chromium/XFCE+VNC/Adreno KGSL，**没有 Wayland/Anland 记录**。

## 机制对比

| 维度 | proot | tawcroot | proroot v1.2.8 |
|---|---|---|---|
| 拦截方式 | ptrace（每 syscall 两次上下文切换 + 用户态翻译） | seccomp `RET_TRAP` + 进程内 SIGSYS | seccomp 陷阱 + **路径类 API 钩子**（dlopen 注入）+ 私有 linker |
| 非路径 syscall | 也被拦（全量翻译） | 仅陷阱表内的 | **直通内核** |
| 源码 | 开源 (GPL) | 开源 (GPL-3.0) | **闭源**，仅 5 个 .so；作者已转做 proroom |
| 最近更新 | 活跃 | 2026-11 前后 | v1.2.8 = 2026-06-17（约 5 个月未动） |
| 硬链接 | `--link2symlink`（symlink 化，弱于真语义） | linkstore（共享 inode、真 `st_nlink`；会改写 rootfs 名字） | anchor + metadata symlink（也改写成员名；有 original-preservation 校验） |
| 绑挂载 | `-b host[:guest]` | `-b SRC:DST[:ro]` | `-b host[:guest]`（同 proot 风格） |
| 伪 root | `-0` | 内建（auxv/getuid/stat） | `-0` |
| 静态二进制 | 原生支持（内核侧翻译） | 原生支持 | 需要 `libproroot-stub-loader.so`（静态加载器路由） |
| 失败可诊断性 | 高（源码 + `-v`） | 高（源码 + 日志） | 低（只有 `PROROOT_VERBOSE=1` 与 `proroot-sigsegv-maps.txt`） |

## 我们关心的实测数字（同一台设备、同一棵 kwin 树）

| 场景 | proot | tawcroot |
|---|---|---|
| kwin 单 TU `g++ -O2 -c src/inputmethod.cpp` | 12.37s | **4.50s（2.75×）** |
| `find /usr -name '*.h'`（8177 个） | 4.10s | **0.46s（8.9×）** |
| `git status --porcelain` | 0.139s | **0.025s（5.6×）** |
| 20 个小编译单元（模拟 make 逐 exec） | 0.796s | **0.271s（2.94×）** |
| 静态桌面 kwin CPU | 293–303 jiffies/10s | 待测（目标 ≤150） |

proroot 的对应数字**尚无**（设备侧还没跑）；它的宣传口径是「zero ptrace」，理论上与 tawcroot 同量级，差别在于它只钩路径 API，非路径 syscall 更便宜。

## proroot 的关键风险（如果要当主力引擎）

1. **闭源**：出问题只能等作者；我们的 kwin/Anland 栈一旦触发它的钩子 bug（例如 `/dev/kgsl-3d0` 的 `realpath`、`/tmp` 下 socket 绑定、`/proc/self/exe` 语义），我们改不了。
   - 作者自己修过一个同类问题：libdrm `realpath("/sys/dev/char/…")` 返回 `EINVAL` 导致 GPU 被禁用（v1.2.8 才修）——说明这类钩子边界确实容易踩。
2. **许可证**：「Free to use in your projects. Redistribution of modified binaries is not permitted.」⇒ 可以用、可以自用改造，但**不能分发改造后的二进制**；我们自己的仓库里不要放它的 .so。
3. **验证面不覆盖我们**：作者冒烟是 XFCE + TigerVNC（X11）、Playwright Chromium、Node、Codex；**没有 Wayland 合成器 + Anland 的案例**。我们的 kwin 是自编 5.23-port backend + surfaceless EGL + KGSL 零拷贝，属于无人区。
4. **维护前景**：作者公告主线转 proroom（一体化 App），本仓库「只维护既有用户」。

## 建议的 A/B 流程（同一套判据，谁先起来谁先测）

1. 引擎 A（tawcroot，默认 shared 模式）——`yoga-plasma-tawc.sh prepare shared && start`
2. 引擎 B（proroot）——`yoga-plasma-proroot.sh install && start`（默认**不**带 `--link2symlink`，rootfs 不被改写）
3. 每次只跑一个引擎，起之前 `hard-restart.sh --clean` 保证 kwin 计数归零。
4. 判据（按顺序）：
   - 会话是否起来：`kwin_wayland`=1、`plasmashell`=1、截图非黑非花
   - `yoga-plasma-tawc.sh bench` / `yoga-plasma-proroot.sh bench` → kwin jiffies/10s
   - 笔：Xournal++ 压感笔迹、笔身双击=右键
   - 键盘：拔插切换软键盘（`yoga-mode-router` 的容器入口需按引擎改）
   - 稳定性：连续用 10 分钟，检查有没有 CSI/黑屏/进程消失
5. 全过才谈「换主力」；任一项失败就退回 proot（`stack-up.sh`），因为 proot 那份 rootfs 与脚本一行没动。

## 附：产物与脚本

- `10_现役脚本/yoga-plasma-tawc.sh`（tawcroot：prepare shared|copy / start / stop / status / bench）
- `10_现役脚本/yoga-plasma-proroot.sh`（proroot：install / start [--copy] / stop / status / bench）
- `10_现役脚本/yoga-plasma-boot.sh`（guest 内的启动脚本，两个引擎共用；不依赖 sudo、跳过音频）
- Windows 侧已缓存官方资产并校验：`D:\AI Desktop\yoga_linux\proroot_assets\*.so`（5 个，sha256 与 v1.2.8 release notes 全部一致）
