#!/usr/bin/env python3
"""yoga-tabletmode-patch — 给 KWin TabletModeManager 加运行时切换 slot

upstream kwin 6.3.6 的 org.kde.KWin.TabletModeManager 只有只读属性
(tabletMode / tabletModeAvailable)，切模式只能改 kwinrc 后重启 kwin。
本补丁新增：

    org.kde.KWin /org/kde/KWin  org.kde.KWin.TabletModeManager.setTabletMode(bool)

行为：设置 m_configuredMode（On/Off）→ 回写 kwinrc [Input] TabletMode=on|off
      → 若 effective 值变化则 emit tabletModeChanged。

幂等：重复运行不会重复插入。
用法：yoga-tabletmode-patch <kwin-src-dir>
"""
import sys
import pathlib

H_MARK = "void setTabletMode(bool on);"
CPP_MARK = "KWin::TabletModeManager::setTabletMode(bool on)"

CPP_FUNC = '''void KWin::TabletModeManager::setTabletMode(bool on)
{
    // yoga patch: runtime switch for tablet mode (upstream 6.3.6 only exposes
    // read-only D-Bus properties, so mode changes require a kwin restart)
    const bool oldEffective = effectiveTabletMode();
    m_configuredMode = on ? ConfiguredMode::On : ConfiguredMode::Off;
    KSharedConfig::Ptr kwinSettings = kwinApp()->config();
    KConfigGroup cg = kwinSettings->group(QStringLiteral("Input"));
    cg.writeEntry("TabletMode", on ? QStringLiteral("on") : QStringLiteral("off"));
    kwinSettings->sync();
    if (effectiveTabletMode() != oldEffective) {
        Q_EMIT tabletModeChanged(effectiveTabletMode());
    }
}

'''


def patch_header(path: pathlib.Path) -> str:
    text = path.read_text(encoding="utf-8")
    if H_MARK in text:
        return "header: already patched"
    anchor = "    bool isTabletModeAvailable() const;"
    if anchor not in text:
        raise SystemExit("header anchor not found")
    block = (
        anchor
        + "\n\npublic Q_SLOTS:\n"
        + "    // yoga patch: 运行时切换平板模式（回写 kwinrc [Input] TabletMode）\n"
        + "    " + H_MARK
    )
    text = text.replace(anchor, block, 1)
    path.write_text(text, encoding="utf-8")
    return "header: patched"


def patch_source(path: pathlib.Path) -> str:
    text = path.read_text(encoding="utf-8")
    if CPP_MARK in text:
        return "source: already patched"
    if "#include <KConfigGroup>" not in text:
        anchor = "#include <QDBusConnection>"
        if anchor not in text:
            raise SystemExit("include anchor not found")
        text = text.replace(anchor, anchor + "\n#include <KConfigGroup>", 1)
    anchor = "KWin::TabletModeManager::ConfiguredMode KWin::TabletModeManager::configuredMode() const"
    if anchor not in text:
        raise SystemExit("source anchor not found")
    text = text.replace(anchor, CPP_FUNC + anchor, 1)
    path.write_text(text, encoding="utf-8")
    return "source: patched"


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    src = pathlib.Path(sys.argv[1])
    h = src / "src" / "tabletmodemanager.h"
    cpp = src / "src" / "tabletmodemanager.cpp"
    for p in (h, cpp):
        if not p.is_file():
            raise SystemExit(f"missing: {p}")
    print(patch_header(h))
    print(patch_source(cpp))


if __name__ == "__main__":
    main()

