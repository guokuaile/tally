# 显示器实施状态

已写入 `Sources/Tally/Displays/` 的公开模式枚举、精确模式选择、两阶段撤销记录与管理员 HiDPI override 安装/恢复；设置页和刘海卡片已接入主任务提供的入口。`Preferences` 新增 `displayTargets`、`displayUndo`，旧配置缺键默认空。管理员授权已移到后台，操作期间共享显示门闩保持占用。覆盖模式选择、切换与恢复失败、外部改动、pending 崩溃语义和尺寸校验的注入测试已写；系统 override 脚本只在隔离的临时目录内由普通用户执行。

`swift test` 完整通过 782 项，其中 `DisplayModeTests` 14 项、`HiDPIOverrideTests` 7 项、`PreferencesTests` 12 项均为 0 失败。日志 `/tmp/tally-desktop-refinement-final-tests.log`。发布构建及 `./scripts/install.sh --build` 已通过，实际安装在 `/Applications/Tally.app`。

真实 UI 已验证：保存目标不切屏；应用 2752×1152 HiDPI/100 Hz 后读回一致；撤销恢复到 2580×1080 HiDPI/100 Hz。最终当前档位与保存目标均为 2580×1080、渲染 5160×2160、100 Hz，撤销记录为空。全新进程直接打开系统页可见显示器卡片，不依赖先进入设置。

自定义 2580×1080 预览显示 5160×2160 渲染；安装确认已取消，没有发起真实管理员写入。原 override 的 SHA-256 为 `070e6692a73c9079b4c9b891aff0a7b71d53356ceb8d4ecb3acf587232c2729b`，原备份为 `827594d1ccc2e8427cb1d552752399799104f10b1f4bd11984d081469130a54d`，检查保持不变。实际管理员安装/恢复与物理重连未验证，不能以临时目录测试替代该结论。
