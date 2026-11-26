# 外接显示器档位配置与手动切换

状态：用户已确认 B 完整显示器管理与壁纸管理；本文件规定已有档位的配置/切换/撤销，管理员配置与壁纸生命周期以 [主规格](desktop-controls.md) 为准。

## 问题

用户已通过本机 `mac-hidpi` 配置并验证 L34W-4C 的 HiDPI 档位，但命令行无法直观看到当前模式与目标模式，也容易把「恢复最初状态」和「撤销刚才的切换」混淆。需要在 Tally 配置常用档位，并在需要时手动应用。

六项范围供确认：

- 结果：从 Tally 选择、保存并手动应用外接屏已有显示模式，可撤销 Tally 的上一次切换。
- 用户：当前用户，以及现有 macOS 15+ / Apple Silicon Tally 使用者。
- 时机：本机 HiDPI 档位已加载，实际切换和退出后保持已验证，命令行试档不方便。
- 成功标准：保存设置不改变屏幕；点击应用才切换；系统设置修改后 Tally 显示实际状态且不抢回；恢复入口含义明确。
- 约束：沿用公开 API、零第三方依赖、现有设置存储、普通设置窗口与刘海系统页。
- 排除项：不自动应用或创建虚拟屏、不承诺提升面板的物理清晰度；新增 HiDPI 档位和系统 override 写入由主规格定义。

## 已确认事实

- `docs/README.md` 的全局边界限制系统功能使用 macOS 公开 API，私有接口例外仅限音乐页。
- `SettingsWindow.swift` 已有普通设置窗口、功能分组与指定分区打开入口；`SystemPage.swift` 已有手动功能卡片。
- `PreferencesStore` 保存用户设置并在变化后调用 `onChange`，因此显示模式变更不能接进通用 `applyPreferences()`。
- 工具链 Xcode 27.2 / Swift 6.4.2，项目最低 macOS 15、Swift 5 语言模式；本功能不改变这些基线。
- 本机 override 已加载；独立编译的只读探针使用 `CGDisplayCopyAllDisplayModes` 可以枚举 2580×1080、2752×1152 的 2× / 100 Hz 档。推荐方案不需要脚本中的 SkyLight 分支。
- 现有脚本的 `restore` 返回首次操作前的 3440×1440、1×、60 Hz；它不是撤销上一条命令。Tally 的撤销记录单独定义，不读取或覆盖脚本的备份。

## 方案选型

| 方案 | 做法与代价 | 不适用条件 |
|---|---|---|
| A：原生公开模式选择，推荐 | 将公开枚举、事务切换、读回核验写入 Tally；设置中保存目标，系统页点击应用。独立运行，不依赖 Python、Xcode 或用户目录下的脚本；没有新管理员权限 | 用户要求在 Tally 内为新屏幕生成系统尚未提供的 HiDPI 档位 |
| B：完整 HiDPI 管理 | 在 A 上增加尺寸生成、系统 override 合并、管理员授权、原始文件备份与配置恢复。需扩展系统配置边界，明确同型号多屏共用 override 的行为；可保持公开模式切换，不必自动引入 SkyLight | 需求只是在本机已有档位间手动切换，新增权限与维护成本不合算 |
| C：按钮调用现有脚本 | Tally 用子进程调用本机 `mac-hidpi`，开发改动少，但依赖个人路径、Python 与 Swift 工具链，脚本升级也影响 App | Tally 发给别人使用、独立安装或维持现有零额外运行依赖的要求 |

用户已确认 B；本文件的 A 是 B 的已有档位子能力。C 不作为发布实现。当前脚本及其已安装配置继续可用；Tally 按主规格兼容现有配置备份。

## 模块与依赖

| id | 模块 | 职责 | 单向依赖 |
|---|---|---|---|
| display-core | `Sources/Tally/Displays/DisplayMode.swift`、`DisplayModeService.swift` | 公共模式与身份、匹配、事务、读回、恢复及操作状态；平台读取和切换可注入 | AppKit / CoreGraphics，既有日志与设置存储 |
| display-settings | `Sources/Tally/Settings/DisplaySettings.swift`、现有设置入口 | 选择显示器与目标、保存目标、显示当前状态及失败原因 | display-core、PreferencesStore |
| display-card | `Sources/Tally/Notch/DisplayCard.swift`、SystemPage | 当前状态、应用、撤销、打开显示器设置 | display-core、display-settings 的导航入口 |

模型放在 App 目标内，hook 与 TallyKit 没有调用需求，不挪进共用库。新增文件分别承载平台操作与两种真实界面，避免把设置窗口的大文件继续塞入新业务。

## 设计

### 可配置内容与界面

- 设置侧栏「功能」组增加「显示器」。选择当前在线的外接屏，展示名称、当前逻辑尺寸、渲染像素、HiDPI / 普通、刷新率；无外接屏显示空状态。
- 分辨率与刷新率从当前可用组合中选择，明确区分同尺寸的 HiDPI 与普通模式。每块显示器保存一个常用目标；选择只改界面草稿，「保存为常用」只写 Tally 设置。设置页「应用所选模式」直接切换下拉框选择且不覆盖常用目标，系统页「应用常用」使用已保存目标。点击应用才改变系统，不能把尚未保存的新选择悄悄替换成旧目标。
- 镜像组不开放切换：公开接口可能同时改变组内其他屏幕，提示先改为扩展显示。第一版只操作外接屏。
- 系统页在左侧显示器卡片中逐屏显示当前桌面尺寸、型号、HiDPI 和刷新率；完整渲染尺寸与目标放在设置及辅助提示中。底部提供「应用常用」「撤销」，右上角进入设置，当前已是常用模式时显示「已应用」。没有保存目标时仅引导配置；没有外接屏时显示未连接状态与刷新入口。
- 相同逻辑尺寸的普通模式不得冒充 HiDPI；目标不在新模式列表时标记不可用，不猜一个接近尺寸或降到 1×。
- 普通设置窗口承担输入，刘海内仅提供点击操作；延续现有卡片、状态色、按钮与无障碍标签，布局变化同步核对动态高度。

### 数据契约

- `DisplayModeSelection`：`width: Int`、`height: Int`、`pixelWidth: Int`、`pixelHeight: Int`、`refreshRate: Double`。尺寸必须为正，刷新率有限且不小于 0；0 代表系统未报告固定值，在 UI 显示「系统默认」，不能写成 0 Hz。
- 不持久化 `CGDirectDisplayID` 或 `ioDisplayModeID`。显示器配置键使用 CoreGraphics UUID 的标准字符串；每次应用按 UUID 重新查在线 ID，并按逻辑尺寸、像素尺寸和刷新率重新匹配模式。
- 新增 `Preferences.displayTargets: [String: DisplayModeSelection]`，默认空；旧配置缺键按空读取。刷新率匹配容差小于 1 Hz；0 只与 0 匹配；有多项时选误差最小者，其余按稳定顺序去重。
- 新增 `Preferences.displayUndo: [String: DisplayUndoRecord]`，默认空。`DisplayUndoRecord` 分别包含 `confirmed: DisplayUndoPoint?`、`pending: DisplayUndoPoint?`，默认均 nil；`DisplayUndoPoint` 包含 `before: DisplayModeSelection`、`applied: DisplayModeSelection`。两部分随同一份 preferences.json 原子保存，不使用覆盖旧 confirmed 的单记录 phase。在实际切换前只更新 pending、保留 confirmed；保存失败就不切换。只有成功读回后，才能在同一次持久化中把 pending 提升为 confirmed 并清空 pending。
- 用户配置与系统当前模式分离。改系统设置只更新当前读数，不覆盖已保存目标、不触发应用。

### 手动切换与撤销

1. 点应用后重读目标屏幕、镜像状态与可用模式；校验目标仍存在。相同当前模式为无操作，不改恢复点，并明确显示「当前已是所选模式，无需切换」。成功切换与撤销也提供明确反馈。
2. 把当前模式及计划应用模式写到 pending，同时保留磁盘上的旧 confirmed，持久化失败则停止。共享服务串行处理 Tally 内部的显示变更；操作期间两处界面的应用与撤销按钮均禁用。
3. 通过 `CGBeginDisplayConfiguration` → `CGConfigureDisplayWithDisplayMode` → `CGCompleteDisplayConfiguration(.permanently)` 提交，仅修改所选屏幕模式。
4. 最多 5 秒异步读取实际模式，匹配后原子保存新的 confirmed 并清空 pending。确认记录写盘失败时明确显示「模式已切换，撤销记录未保存」，保留旧 confirmed 和不可执行的 pending，不谎报模式未切换。未验证成功时按下一段的条件决定是否回退，分别报告原始失败与恢复结果；不在成功后再依赖一次无关屏幕的全量枚举决定成败。
5. 成功确认后「撤销上次切换」指向这次操作前的模式。它跨 Tally 重启保留，每块屏只留一条 confirmed，不是首次安装基线。启动遇到 pending 只读当前状态并显示未确认，不自动提交、回退或补成 confirmed；旧 confirmed 仍完整保留，并按正常实时匹配条件决定能否撤销。
6. 撤销只读取 confirmed，必须确认当前模式仍匹配其中的 `applied`、屏幕身份一致且 `before` 仍可用。系统设置或其他程序已改走时禁用旧撤销并解释原因，尽量避免覆盖用户的新选择。用户可在设置中明确选择需要的模式。
7. 撤销成功后清空该恢复记录。恢复点的清除若落盘失败，显示保存错误；重新启动后因为当前已不匹配 `applied`，旧记录不能自动执行。

如果切换、失败回退与外部变更交错，按实时状态决定：原模式已经生效时直接报告失败且保持，只清 pending、保留旧 confirmed；只有重新确认身份、当前仍为本次目标且原模式可用时，才允许尝试回退，回退成功后同样只清 pending。读取报错、读到第三种模式、身份丢失或原模式不可用时停止显示写入，保留 pending 并报告未知/外部改变，不能因读回失败而盲目恢复。恢复记录的任何写盘失败都显式报告，不能让未确认记录变成可执行撤销。

崩溃验收必须覆盖「旧 confirmed=A→B；新 pending=B→C 已保存；尚未切屏就崩溃」：重启后当前仍为 B，旧 confirmed 仍能在显式点击时回到 A。若崩溃发生在已经切到 C、但尚未确认之后，不能用 pending 自动回到 B，也不能用与当前不匹配的旧 confirmed 撤销；提示用设置选择需要的模式。

外部程序不参与 Tally 内部串行队列。上述重新读回只能尽力识别已发生的外部改变，读取与提交之间仍有竞争窗口，也无法仅凭相同模式值识别外部程序是否重新设置过同一档位；不承诺对系统设置提供跨进程原子锁或「永不覆盖」保证。验收注入已可观测的改变，验证停止写入；同时操作的剩余风险在使用说明说明。

### 与系统设置共存

- 系统只有一份当前显示状态，Tally 是另一个手动控制入口；最后成功完成的设置为准。退出 Tally 不恢复显示模式。
- 打开设置页、进入系统页以及显示配置变化时只刷新读取。优先复用既有屏幕变化事件；确需 CoreGraphics 回调时仅在界面可见期间注册，并在回调中安排读取，不在回调内修改显示配置。
- 不在登录、唤醒、重连、切页、保存设置、通用 `PreferencesStore.onChange` 时自动应用；不增加常驻切换进程或定时纠偏。
- `.permanently` 是请求跨登录保存；Apple 文档说明某些模式会退为当前会话有效，界面与说明不承诺所有连接条件下都跨重启保持。
- A 不写 `/Library/Displays`，不申请管理员权限、辅助功能或屏幕录制权限，不读取 shell 配置。现有独立脚本只在用户执行时运行，两者不会自动互相改回。

## 任务与验证点

| # | 可验收行为 | 文件或表面 | 验证命令与操作 | 通过标准 |
|---|---|---|---|---|
| 1 | 设置里读到真实外接屏，可保存目标但不切屏 | display-core 模型与枚举、DisplaySettings、SettingsWindow、Preferences、测试 | `swift test --filter DisplayModeTests`；`swift test --filter PreferencesTests` | 缺键兼容、0 Hz、模式区分与消失、UUID 重识别均覆盖；保存设置调用平台变更次数为 0；枚举与实机公开探针一致 |
| 2 | 点击应用及撤销具有准确恢复语义 | display-core 事务、DisplaySettings、恢复记录与测试 | `swift test --filter DisplayModeServiceTests` | 正常切换、提交失败、读回不符/读取报错、回退失败、两阶段存盘失败、pending 重启、同时请求、已可观测的外部改变、拔线均有可证伪断言；读取报错或第三种模式时回退写入次数为 0；单元测试全部注入平台边界，不切真实屏幕 |
| 3 | 刘海系统页可手动控制，系统设置改动不被抢回 | DisplayCard、SystemPage、现有刷新/布局入口、DemoData、文档 | `swift test`；`./scripts/install.sh --build`；`open -a Tally --args --open system` | 全套回归通过，安装到 /Applications；从真实 UI 应用和撤销，独立读回；系统设置手动改后只刷新状态且旧撤销失效；启动/退出无自动写入；假数据演示不读写真实显示器 |

任务 1 同时涉及模型、现有持久化和设置导航，属于一条完整的「保存但不应用」路径；任务 3 的卡片、刷新与布局必须一起验收，不按技术层拆成不可使用的中间功能。确认实施 A 的范围也包含项目 AGENTS 要求的本机构建安装、接管旧 Tally 实例及有限真机切换验收；实施前检查并告知正在运行的保持唤醒、清洁锁等功能，沿用项目安装脚本的收尾流程，不强杀跳过。真机验收用两档可恢复模式，结束回到用户认可的 2580×1080 HiDPI / 100 Hz；不自动重启机器或要求用户反复插线，不包含对外发布。

当前验证证据仅为现有脚本与公开模式探针。上表的新测试类和界面尚未实现，不能将测试筛选返回空用例记为通过；实施时检查实际执行用例数。

## 预算与停止

质量阶段沿用建设，B 已获用户确认，系统写入限定为主规格中的范围。20 分钟没有新证据或同一路径失败两次就停止报告；复审三轮仍有阻断项则重新比较方案。若公开接口不能覆盖已保存目标，报告不可用，不引入私有接口兜底。

## Review Focus

1. 同型号双外接屏、UUID/运行 ID 变化和镜像组，不能切错屏幕（任务 1、2）。
2. 系统设置或另一个工具在应用/撤销期间改动、模式消失，对已可观测的第三方新状态停止写入；不把剩余竞争窗口宣称为原子隔离（任务 2、3）。
3. 恢复点写盘失败、切换成功但恢复记录清理失败、读取失败，UI 必须与实际结果一致（任务 2）。
4. 0 Hz、自适应刷新率、HiDPI 与普通模式同名，不能默默降低清晰度或误选（任务 1、2）。
5. 多屏卡片溢出、非激活面板输入限制、演示模式副作用与启动/退出期间意外切屏（任务 3）。

## 影响面与回退

只扩展 Tally App 的设置、系统页、显示器服务与向后兼容的偏好字段；不改 TallyHook、TallyKit 契约、音乐助手、现有 HiDPI 脚本、全局指令或其他系统配置。使用原生公开 API，无新增包或脚本依赖。移除新入口不会撤销用户当前显示模式，先用撤销或系统设置恢复后再回退代码。恢复点仅影响用户显式触发的撤销，不在启动时自动执行。

依据：[Apple 显示配置事务](https://developer.apple.com/documentation/coregraphics/cgconfiguredisplaywithdisplaymode(_:_:_:_:))、[配置变更回调](https://developer.apple.com/documentation/coregraphics/cgdisplayreconfigurationcallback)、[永久作用域](https://developer.apple.com/documentation/coregraphics/cgconfigureoption/permanently)。本机脚本来源及许可保存在能力仓库 `bin/shared/mac-hidpi-LICENSES.md`；若移植代码片段，按原 MIT 声明补 Tally 的 NOTICE，不整包复制。
