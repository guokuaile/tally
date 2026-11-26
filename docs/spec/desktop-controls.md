# 显示器与壁纸管理

## 范围与授权

用户明确确认：「继续播放。按推荐的“ B＋壁纸管理”来」。实施完整显示器管理及壁纸图形界面；退出 Tally 后壁纸继续播放。包含本机构建安装、可恢复的真机验收、接管旧壁纸自启动；不包含对外发布、删除原播放器或素材、整机重启。当前实施基线为 `e96a8be`；既有未提交文件只有显示器子规格。

结果：日常选分辨率、创建 HiDPI 档位、应用与恢复、选壁纸目录、设置间隔、播放/暂停/下一张/停止均通过 Tally 完成。平台保持 macOS 15+、Apple Silicon、零第三方依赖。显示变更只在明确点击时发生；壁纸则由单独的原生播放器持续运行。

## 选型

- 显示器：Swift 原生公开模式枚举与切换，结合受限的管理员 override 安装/恢复。系统配置写入遵循已验证 mac-hidpi 的合并、备份和并发保护，不加入 SkyLight、虚拟屏或自动重应用。选择 B 是因为仅切已有档位仍要求用命令行准备新屏幕。
- 壁纸：从已有 Swift 播放器提取播放能力，编译为随 Tally.app 打包的 `TallyWallpaper.app/Contents/MacOS/tally-wallpaper`，位于主包 `Contents/Library/LoginItems/`，由用户级 LaunchAgent 管理。辅助包使用独立标识 `com.aiden.tally.wallpaper` 与 `LSUIElement`，避免 Launch Services 把独立播放器当成主应用而阻止主界面重开。Tally 用本机 IPC 控制并读取真实状态。退出 Tally 不关闭播放器；App 崩溃不影响壁纸。
- 不采用主进程内播放器：会随 Tally 退出，违反用户确认。不采用执行用户目录内 shell/Swift 源码：分发后依赖个人路径与编译工具链。

系统以 [CFBundleIdentifier](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier) 识别独立应用；内嵌播放器因此保留自己的 Info.plist，不与主进程共用应用标识。

## 模块与契约

| id | 模块 | 单向依赖与职责 |
|---|---|---|
| displays | Tally/Displays、DisplaySettings、DisplayCard | AppKit/CoreGraphics 与现有偏好；档位、事务、撤销、配置安装/恢复 |
| wallpaper-kit | TallyWallpaperKit | Foundation/Darwin；配置、状态、播放列表与受限本机控制协议，供两个真实调用目标共用 |
| wallpaper-player | TallyWallpaper | wallpaper-kit、AppKit/AVFoundation/ImageIO；桌面窗口、轮播、控制服务与状态 |
| wallpaper-ui | Tally/Wallpaper、WallpaperSettings、WallpaperCard | wallpaper-kit、现有 Subprocess；配置、用户 LaunchAgent、旧入口接管和 UI |
| app-shell | 现有设置窗口、系统页、打包安装 | 上述 UI；仅负责入口、部署与验证 |

设置增加「显示器」「壁纸」两项。系统页提供紧凑操作卡片，长表单留在设置窗口。新视图沿用现有 Form、Card、提示与无障碍样式；演示模式和测试不访问真实屏幕、LaunchAgent 或个人目录。

### 显示器

已有档位的选择、保存、手动应用、撤销语义见 [显示器子规格](display-presets.md)。公开枚举读不到的档位明确提示不可用，不引入私有接口兜底。

设置中增加自定义 HiDPI 尺寸输入、原生比例校验、生成预览、安装按钮与独立的「恢复档位配置」。输入为正整数，桌面至少 800×600、不大于可信的面板基准尺寸、比例误差不超过 0.5%；数据是宽高各乘 2 的大端 uint32。尺寸写入前显示桌面尺寸、渲染尺寸与目标型号。无法可靠识别基准时拒绝自动生成，不能把 HiDPI 渲染尺寸当面板原生尺寸。

配置安装只触及 `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<hex>/DisplayProductID-<hex>`，标识来自选中屏幕、数值校验后生成固定路径；同型号多屏共用此配置，UI 写明。先读取原 plist，保留非 scale-resolutions 键、合并并去重档位；取得授权后由 root 进程在第一次写入前重新校验目标/备份哈希及全部父路径无软链接，不能仅依赖 App 预检查。root 目录内创建临时文件，plutil 验证后原子替换。只通过系统管理员授权弹窗取得单次写权限，不保存密码、不装 sudoers 或 root 常驻服务。

与现有 mac-hidpi 共享 `/Library/Application Support/MacHiDPI/<vendor>-<product>/backup.plist` 的 v1 格式（originalExists、original、installed、可选 previousInstalled），兼容已有最初备份，不能把当前已修改文件重新冒充原件。先写备份再写配置；同时记录前一 installed，使中断后仍可恢复。外部工具更改目标时拒绝覆盖。原先没有配置的恢复使用唯一归档名保留已安装文件，不覆盖其他归档。代码中保留上游 MIT 归属。

写入成功不等于新模式已加载；显示「需重新连接显示器」，刷新后才开放应用。此操作不自动切屏、不自动拔插或重启。恢复档位配置与撤销显示模式分别呈现；恢复配置前提示新档位下次重连可能消失，不假装已恢复当前模式。

### 壁纸播放器及配置

复用当前播放器的图片/视频混播、洗牌袋不连播、每槽扫描新增/删除文件、图片降采样及 EXIF、静音循环视频、1 秒淡入淡出、图标下方窗口、鼠标穿透、多屏同步与屏幕休眠暂停。用户暂停必须暂停轮播与视频，屏幕唤醒不能取消手动暂停。手动下一张在暂停状态下仍保留暂停。目录为空时露出系统壁纸并显示状态；坏素材记录错误并继续可用素材，不能把空白层当成功。

`WallpaperConfiguration` 含 `sources: [String]`（绝对本地目录/文件）、`slotSeconds: Double`（10～86400，默认 300）、`launchAtLogin: Bool`（默认 false）。首次界面可识别本机旧素材目录作为候选，不自动播放或切换后台服务。保存配置必须校验并原子落盘；没有已确认配置则播放器不能开始。素材原地使用，不搬动或复制用户媒体。

持久配置、seen 清单、有限大小日志与运行状态统一放在 `~/Library/Application Support/Tally/Wallpaper/`，不写 .app 包，不覆盖旧播放器的 seen.txt/log。目录权限限制为当前用户。共享 IPC 支持 status、pause、resume、next、reload；命令只包含枚举，不接受 shell 字符串或任意执行路径。请求响应有长度与时间上限；状态包含真实 pid、播放/暂停状态、当前条目、条目数和错误。App 不能因命令已发出就显示成功，须核对回复；连接断开显示不可用，不拿旧状态冒充在运行。

播放器独占运行目录/锁与控制端点。重复启动不得删除活实例的端点或创建第二层壁纸。IPC 仅为当前用户本地连接，不监听 TCP 端口，不调用网络。测试使用临时目录及隔离端点，不触碰真实桌面。

### 自启、退出与接管

用户级任务使用专用 label `com.aiden.tally.wallpaper`，ProgramArguments 指向当前已安装 App 内的播放器。开启播放启动任务，停止播放卸载任务并露出系统壁纸；确认停止后才报告已停止。登录自启与当前播放分开：勾选自启才在 `~/Library/LaunchAgents` 保留有效登录入口；未勾时使用运行数据目录里的临时会话任务，退出 Tally 后仍播放，下一次登录不启动。不得借 Tally 自身登录启动而擅自开始壁纸。

改配置时由已运行播放器 reload，并保持用户暂停状态；启动任务失败、超时、权限不足、正在退出等均显示准确原因。launchctl 操作通过现有有截止时间的 Subprocess，不在 UI 主线程阻塞。

旧入口为 `com.aiden.video-wallpaper`。只有用户点击接管/启动新播放器时迁移：先确认新二进制、配置与目录可用，记下旧任务运行/禁用状态，禁用旧登录任务并卸载，等待旧实例确实退出，再启动新实例并核对健康。失败时撤销新任务并尝试恢复旧状态，回退失败明确提示；保留旧 plist 链接、源码、二进制与所有素材。禁止按进程名杀掉未知同名程序。持久记录旧入口由 Tally 接管的事实，使卸载/回退可恢复；新旧任务不并行播放。

安装 Tally 新版本时，若新壁纸任务正在运行，应记录并卸载任务、等待准确 pid 退出，再替换 App，随后按原播放/自启/暂停意图恢复新任务；只替换 App 不允许旧二进制无限运行。替换前校验新包签名，原 App 移到本机备份位置而不直接删除；复制、签名核验、播放器重启失败时恢复原 App 和原任务并返回非零，回退失败单独报告。普通关闭 Tally 窗口或退出 App 都不卸载壁纸任务。卸载 App 的现有流程也须撤销自有任务，保留素材，并说明恢复旧入口的方法。

## 任务与验收

| # | 完整行为与归属 | 验证 | 通过标准 |
|---|---|---|---|
| 1 | displays：配置并应用已有模式、撤销 | DisplayModeTests/DisplayModeServiceTests、偏好回归；真实 UI | 仅手动切换、准确读回；外部已改走时不盲目撤销；pending 不冒充 confirmed；旧撤销记录跨失败保留 |
| 2 | displays：创建/安装/恢复新档位 | HiDPIOverrideTests，临时目录执行授权脚本；真机预览/既有配置检查 | 保留原字节与外部键、兼容旧备份、拒绝外部变更；取消授权无系统写入；中断仍可恢复；UI 不误报已经启用 |
| 3 | wallpaper-player：播放与控制 | TallyWallpaperKitTests；隔离 helper 控制与窗口验收 | 混播/队列/暂停/休眠/坏素材正确；IPC 超时与重复启动有断言；真实 next/pause/resume 可读回 |
| 4 | wallpaper-ui：配置、独立运行与接管 | WallpaperServiceTests；真实设置页、旧入口迁移与退出 Tally 验收 | 无需 shell 操作；一个播放器；退出 Tally 后 pid 存活且视频继续；开关自启不混淆当前状态；迁移失败能回退 |
| 5 | app-shell：打包、入口与回归 | `swift test`、`./scripts/install.sh --build`、签名校验、设置/系统页截图 | 全套测试绿；无运行时 Python/Swift 源码依赖；所有入口可见且无遮挡；当前显示最终保持 2580×1080 HiDPI/100 Hz，壁纸继续播放 |

每条任务跨模型、执行、UI 与测试是为了完整行为可验收。共同编译由主执行者串行负责，避免 SwiftPM 同目录并发写；独立实现者只修改分配文件。已授权本机验证不要求再次确认；系统管理员密码只在 macOS 原生弹窗输入。

## Review Focus 与停止

重点复核 root 路径/并发原文件保护、pending/confirmed 恢复记录、旧播放器迁移失败、App 更新期间独立任务、IPC 信任边界与演示模式副作用。20 分钟无新证据或同一路径失败两次先报告并调整；复审三轮仍有阻断项重新划分实现。不能通过绕过测试、私有接口兜底或删除原数据完成验收。

## 当前状态

已实现并安装到 `/Applications/Tally.app`，782 项 Swift 测试与 7 项安装隔离测试通过。真实设置页已验证显示模式应用与撤销、壁纸控制、旧入口接管/恢复、退出主 App 后视频继续以及暂停跨更新保留。显示器最终为 2580×1080 HiDPI/100 Hz；壁纸按原两个目录、300 秒间隔混播，登录后播放开启。

真实管理员配置写入、物理重连、整机重启与休眠唤醒未执行；配置安装/恢复脚本仅在隔离目录验证，真实 UI 已验证预览与取消。准确命令、证据路径和其余验收边界见 [实施状态](desktop-controls-status.md)。
