# 「系统」页

> 「硬件」「电池」并排，接着是两列独立控制卡片：第一行显示器 / 壁纸，第二行保持唤醒 / 清洁锁；「压力」与内存大户放在页面最下方。每张卡将标题、主状态、辅助说明、操作分层，不把信息挤在同一行。全走公开 API，只在停在这页时每 2 秒采一次。

## 硬件（一次性，`HardwareInfo.read()`）

「Apple M3 Max · 16 核 · 48 GB」「macOS 26.2 · 已开机 1 天 14 小时」。芯片 `machdep.cpu.brand_string`；核心 `hw.perflevel0.physicalcpu` + `hw.perflevel1.physicalcpu`（Intel 没有能效核就用 `hw.physicalcpu`）；内存 `hw.memsize`；版本 `ProcessInfo.operatingSystemVersion`（补丁号非 0 才带）；开机 `kern.boottime`，文案满一天「1 天 13 小时」、不满一天「13 小时 5 分钟」、不满一小时「5 分钟」。第一次展开时读，标题行 ↻ 重读。

## 电池（`BatteryHealth.read()`）

IOKit 注册表 `AppleSmartBattery`（`ioreg` 就能看，不是私有 API）：电量 `CurrentCapacity`（Apple Silicon 上本身是百分比）、状态（`IsCharging` → 充电中；插电且不充电：≥ 95% 已充满、否则「接电源」——优化充电停在 80% 就是这样；没插电放电）、最大容量取「系统信息 → 电源」的同一个数（叫法也跟它：系统里 93% 那栏就叫「最大容量」，「健康度」是另一项文字状况——正常 / Normal，两个混在一起会有歧义）（`system_profiler -xml SPPowerDataType` 的 `sppower_battery_health_maximum_capacity`，0.15 秒，只在打开这一页时读一次，后台读不挡主线程）；取不到才退回 `AppleRawMaxCapacity ÷ DesignCapacity`。不直接用比值是因为对不上：本机 ioreg 算出来 89%（`NominalChargeCapacity` 那版 91%），系统显示 93%——系统那个数是平滑过的，不是这两个字段的直接比值、循环 `CycleCount`。一行「79% 放电 · 健康 89% · 循环 134 次」，读不到的项「—」；没电池显示「无电池」。颜色：接着电源（充电中 / 已充满 / 接电源）一律绿，放电 ≤ 10% 红、≤ 20% 黄；健康 ≥ 80% 绿、≥ 60% 黄、其余红。不做温度（字段单位机型不一）和风扇；GPU 利用率见下面「压力」。

电池卡片第二行是废纸篓，见下。

## 保持唤醒（`KeepAwakeCard`）

四项功能分别使用现有圆角卡片，按两列布局。显示器卡以当前逻辑尺寸为主、名称 / HiDPI / 刷新率为辅，底部应用常用与撤销，右上角进入设置；无外接屏时显示未连接。壁纸卡显示播放状态与当前文件名，底部暂停/继续、下一张、停止，右上角进入设置。完整路径和模式可悬停查看，失败信息仍在对应卡片内显示。机制与生命周期见 [desktop.md](desktop.md)。

机制在 [monitors.md](monitors.md)，这里只说界面。卡片上方显示未开启/持续开启/结束时间，辅助行解释休眠状态；底部直接提供「不限」「1 小时」胶囊按钮，当前档位高亮，开启后另有「关闭」按钮。「更多」胶囊菜单包含 15 分钟、30 分钟、2 小时、4 小时、8 小时、9 小时和自定义；右上角选项菜单保留「合盖也不休眠」「屏幕也常亮」及勾选状态。

「更多」菜单内「自定义时长…」不直接启动，而是在卡片中展开分钟输入框、加减按钮与开始/取消操作，适应半宽卡片。可直接输入 15–1440 的整数分钟，保留到分钟的精度；加减仍每次 15 分钟，夹在 15 分钟到 24 小时。输入为空、非整数或越界时显示范围提示，不能开始。编辑输入框时数字键不切页、⌘数字不跳会话；鼠标移出不会打断编辑，点外或显式收起仍会取消未提交输入。点击「开始」或回车后编辑区收起，`Preferences.keepAwakeCustomMinutes` 记住选择；取消不保存，下次进入从上次确认的时长编辑，未设过默认 90 分钟。

「合盖也不休眠」动的是系统级的 `SleepDisabled`，第一次开要装一条免密规则、输一次密码，之后开关都不弹框（机制、自动恢复与残留处理都在 [monitors.md](monitors.md)）；它开着时下面多一行小字提示合盖会发热。上一轮被强杀留下的残留，在没有免密规则可用时出一行橙字加一颗「恢复」胶囊。

标题行使用 72×28pt 的「咖啡图标＋唤醒」胶囊作为快捷开关，开启后显示橙色「唤醒中」；整块区域可点击，右键保留时长菜单。系统页卡片把不限、1 小时和更多时长直接呈现，适合主动选时长。设置里关掉「标题行「保持唤醒」按钮」时这张卡片一起不画——那个开关关掉整个功能，留着控件会点了没反应。

## 清洁锁（`InputLockCard`）

机制在 [monitors.md](monitors.md)，这里只说这张卡片。标题右侧显示自动解锁时长；主体分别显示锁定状态、解锁提示和操作，完整解锁提示允许换行。

| 状态 | 左边 | 右边 |
|---|---|---|
| 没锁 | 「未锁定」及自动解锁说明 | 「锁键盘」「键盘 + 触控板」 |
| 只锁键盘 | 「键盘已锁」及「1:47 后自动解锁 · ⌥⇧T 解锁」 | 「解锁」（橙色） |
| 键盘 + 触控板 | 「键盘与触控板已锁」及完整解锁提示 | 不放按钮 |

全锁时点击也被吞了、光标也钉住了，放一颗「解锁」只会点了没反应，所以右边空着，解锁办法写在状态里。锁着时标题的图标从键盘换成锁。没锁成（没给辅助功能权限、有密码框正等着输入）在下面出一行橙字说原因，不说就是「点了没反应」。倒计时每秒走一格；锁着时面板被钉住，光标移开也不收。

这张卡片恒在，没有设置开关：不点它就什么都不起。

## 压力（`SystemSampler`，每 2 秒）

| 项 | 来源 | 颜色 |
|---|---|---|
| 内存 | `host_statistics64`：已用 = (active + wired + compressed) × 页大小，和活动监视器口径一致；后面跟内核的压力等级 `kern.memorystatus_vm_pressure_level`（1 正常、2 偏紧、4 严重） | 已用 ≥ 90% 红、≥ 75% 黄 |
| CPU | `host_processor_info` 两次采样的 tick 差分（所有核汇总），第一次为 nil | ≥ 90% 红、≥ 70% 黄 |
| GPU | IOKit 注册表 `IOAccelerator` 的 `PerformanceStatistics` → `Device Utilization %`，除以 100 转成占比；只接受 0–100 的有限数值，缺失或无效显示「—」 | ≥ 90% 红、≥ 70% 黄 |
| 磁盘 | 系统卷 `volumeAvailableCapacityForImportantUsage` / `volumeTotalCapacity` | 可用 < 10% 红、< 20% 黄 |
| 交换 | `vm.swapusage`，用了才显示 | 中性 |
| 内存大户 | `proc_listallpids` + `proc_pid_rusage` 的 `ri_phys_footprint`，前三名列表；名字是纯版本号且路径含 `/claude/` 的显示「claude」，读不到名字显示「pid N」 | — |

内存占一行，CPU / GPU 并排，磁盘占一行。每项各自失败互不影响，采不到显示「—」。数值格式「已用 17.4 / 48 GB · 正常」（两边单位相同只写一次）。GPU 与电池一样只用公开 IOKit API 读注册表，不加载私有框架、不提权；驱动提供的统计字段不是稳定契约，系统不再提供时保留 GPU 一行并显示「—」，不把缺失当作 0%。

## 废纸篓（`TrashInfo`）

只看 `~/.Trash`，不碰外接盘的 `.Trashes` 和 iCloud。`scan()` 在后台枚举：顶层可见项数 + 递归已分配大小，展开时和清空后各扫一次（后台任务带轮次编号，晚回来的不盖新的）。一行「废纸篓 118 MB · 25 项」+「清空」胶囊按钮（空时禁用）：先 `NSAlert`「清空废纸篓？将永久删除 N 项（大小），不能撤销。」（包在 `NotchPanel.steppingAside` 里，否则弹框被面板盖住，见 [panel.md](panel.md)），确认后逐个顶层项 `removeItem`（含隐藏文件，某项失败记日志继续），走 FileManager 不走 Finder，所以不弹「想控制 Finder」的授权；完成后按钮旁绿字 4 秒「已清空 N 项」（有失败「删了 N 项，M 项失败」）。

## 验证

```bash
swift test --filter SystemSamplerTests
pkill -x Tally; while pgrep -x Tally >/dev/null; do sleep 0.5; done
open -a Tally --args --open system && sleep 7 && screencapture -R256,0,1000,480 -x /tmp/tally-system.png
sysctl -n machdep.cpu.brand_string hw.memsize kern.memorystatus_vm_pressure_level; uptime; du -sh ~/.Trash
ioreg -r -c AppleSmartBattery | grep -E '"(CycleCount|DesignCapacity|AppleRawMaxCapacity|CurrentCapacity)"'
```

用例：CPU 差分公式、GPU 百分比解析（正常、零、满载、缺失、非法类型与越界）、五项颜色阈值、`ByteFormat` 四档与去零、压力等级映射、电池三态与健康百分比、开机时长三档文案、核心与版本文案、真实采样的芯片与内存总量等于 `sysctl` 命令输出、内存大户前三非空且降序、`TrashInfo` 在临时目录上扫与清。截图检查两列卡片边界、标题与操作对齐，主状态与说明有明确层次，半宽卡片内按钮不挤压或截断。验证唤醒时长与选项菜单、自定义展开/取消、壁纸暂停/继续/下一张和显示器设置入口，锁定状态必须保留完整解锁提示；异常或多屏使内容超高时仍可滚动。
