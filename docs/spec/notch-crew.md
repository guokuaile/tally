# 刘海小人（小刻）

## 问题

Tally 的会话状态只有展开面板和一闪而过的提示药丸两条路：面板收着时不知道哪个项目的 agent 在等审批、哪个跑完了、哪个失联了；提示条 5 秒就没，错过了只能展开翻列表。用户要的是像 Peeko 那样，每个项目一个小角色常驻在刘海旁边，看一眼就知道状态，悬停看详情，点一下跳回终端。

不做的代价：多项目并行跑 agent 时反复展开面板查状态，等审批的会话晚发现几分钟是常态。

六行复述：

- **结果**：面板闭合时刘海两侧各一排小角色，一个角色一个项目，身体动作表达该项目最急的会话状态；悬停出气泡，点击跳回终端或展开会话列表；新项目第一次出现时弹一张工牌。
- **用户**：本机日常跑多个 Claude Code / Codex 会话的开发者，以及拿到 DMG 的其他人（默认开，不想要可关）。
- **为什么是现在**：角色动作已经定稿（第 7 版预览：黑玻璃球身、六个状态），会话数据层、跳回终端、提示药丸、减少动态效果都已经有，只差一个常驻的壳。
- **成功标准**：见「任务与验证点」；关键三条——六个状态真机上看得出区别且忠于会话文件，6 个角色常驻时 Tally 的 CPU 不超过 3%，关掉开关后闭合态和现在一字不差。
- **约束**：会话事件只有 hook 给的那些（Codex 没有等输入、没有压缩中）；闭合态刘海 189pt 里 185 是摄像头外壳不能画；角色窗口会盖住菜单栏那一段；全屏隐藏、截屏隐藏、模态让路、减少动态效果都要跟面板一致；零第三方依赖；不改 hook 文件契约。
- **不做什么**：见下一节。

## 不做什么

- 不改 `tally-hook` 写的状态文件契约，不新增 hook 事件，不猜 Codex 的等输入：Codex 会话回合中途提问时角色照常显示「在跑」，气泡里说明。
- 不按 git 根合并项目：项目键就是会话记录里的首见 `cwd`（规范化后），`/repo` 与 `/repo/sub` 是两个角色。
- 不做性格、爱好之类的装饰文案；工牌只写项目名和提供方、模型。
- 不做用户逐项目指定角色或配色；配色由项目路径决定、稳定不变，用户只能选套系（黑玻璃 / 渐变）。
- 不在面板展开态画角色；展开时翅膀整个隐藏。
- 不改 AI 页会话行的动作：六个老片段按原参数重采样，帧数、时间线不变；AI 页唯一的可见变化是「身体碎片按身体材质画」这条绘制规则让压缩中的三点变成三个小玻璃球，是有意的统一。
- 不做外接屏、无刘海屏上的角色；没有刘海就什么都没有，不改发系统通知。
- 不做菜单栏项目碰撞检测；翅膀宽度由「每侧最多几个」限死，撞到谁由用户调小。
- 不把角色塞进现有刘海面板窗口（理由见方案选型）。

## 方案选型

- **翅膀是独立窗口（选定）**：刘海面板原样不动，左右各一个非激活 `NSPanel` 贴着刘海面板的两侧，角色画在里面；悬停气泡是第三个小窗口。代价：三类新窗口要接进全屏隐藏、截屏隐藏、屏幕变化、模态让路（`NotchPanel.steppingAside` 按类型过滤，要加一类），两块黑要严丝合缝。选它的理由全在仓库里：闭合态面板的追踪区铺满整个窗口（`NotchHostView.updateTrackingAreas`），一碰就 150 ms 展开；黑色 `NotchShape` 填满 bounds；右键在闭合态任何位置都弹 Tally 菜单；`state.notchWidth` 同时喂 `headerGap` 和 `hitsNotch`，闭合宽一变展开态页签就会钻到刘海底下；`docs/panel.md` 已写明「frame 比黑块大一圈牵连追踪区和点击，不做」；独立药丸那份 spec 为同样的理由选了独立窗口并把四个接入点都铺好了。
- 把闭合态面板加宽、在同一个窗口里画翅膀（拒绝）：上面每一条耦合都要拆：追踪区按位置分段、黑块按刘海宽裁、右键按位置分流、拖放区裁掉翅膀、宽度动画要区分「闭合但变宽」。改的是最脆的那段代码（首次悬停闪、钉住误收都在这里修过）。它错在：翅膀的生命周期（有项目才有）和面板的开合是两件事，硬塞进一个 frame 里。
- 角色挂在刘海正下方的常驻条（拒绝）：不盖菜单栏，但永久盖住最大化窗口标题栏正中（标题文字就在那儿），比盖菜单栏空白段更碍事。只有真机证明翅膀和菜单栏项目冲突到不可接受时再回头考虑。

## 模块表

| id | 模块 | 职责 | 单向依赖 | 构建顺序 |
|---|---|---|---|---|
| crew-clips | `Resources/bloub/export.cjs`、`frames.json` | 七个小刻片段的采样与新字段 | 无 | 1 |
| crew-render | `BloubArt`（`SessionEyes.swift`）、`CrewStyle.swift`（含 `CrewMood` 枚举与调色板表） | 解码新字段，按套系、调色板画角色 | crew-clips | 2 |
| crew-roster | `CrewRoster.swift`（纯函数） | 会话 → 项目 → 状态折叠、排序、槽位、溢出、身份调色板、新项目检测 | `SessionRecord`、crew-render（只用 `CrewMood`） | 3 |
| crew-settings | `Preferences.swift`、`SettingsPage.swift`、`Demo/DemoData.swift` | 三个偏好键与设置节 | `Preferences` | 4 |
| crew-panel | `CrewPanel.swift`（窗口 + `CrewStrip` 视图 + `CrewController` 协调者，声明 `rosterChanged` 与 `onHover` 两个回调属性）、`CrewGeometry.swift`、`NotchPanel.swift`（`steppingAside` 类型过滤）、`NotchController.swift`（持有 `CrewController`，五个接入点）、`Demo/DemoData.swift` | 翅膀窗口、几何、动画时钟、名册订阅、悬停槽位回调、接入全屏 / 截屏 / 屏幕变化 / 模态 | crew-render、crew-roster、crew-settings、`SessionStore`（`CrewController` 不反向引用 `NotchController`，要展开面板走注入的闭包） | 5 |
| crew-bubble | `CrewBubble.swift`、`NotchController.swift`（接 `onHover`、注入 `openAIPage` 闭包）、`NotchPanel.swift`（类型过滤加气泡） | 悬停气泡、点击分派（纯函数）、多会话列表、+N 展开面板 | crew-panel（设置它的 `onHover` 回调）、crew-roster、`SessionJump` | 6 |
| crew-badge | `PillQueue` / `Peek` / `PeekIcon` 扩展、`NotchController.swift`（订阅 `rosterChanged`） | 新项目工牌的样式、`newcomers` 的调用与入队 | crew-panel（订阅它在任务 5 就声明好的 `rosterChanged`）、crew-roster、crew-render、crew-settings | 7 |

本 spec 引用的现有语义以 `docs/ai.md`（`SessionRecord` 的 `displayOrder` / `backgroundWork` / `isStale` / `displayTitle` / `modelLabel`、`SessionJump`）和 `docs/panel.md`（`PillQueue` 三条并显与清空规则、`peekSessionSeconds`、刘海面板 level `.mainMenu + 3`、收起后 400 ms 忽略进入）为准，这里不复述。

## 设计

### 片段（crew-clips）

`frames.json` 的 `clips` 里新增七个键，和现有六个并存，同一份文件、同一套解码器：

| 键 | 时间线（bloub 状态 · 秒） | 表情 | 附加 | 循环 | 静态帧时刻 |
|---|---|---|---|---|---|
| `crew-run` | idle 3 → swirl 1.3 | 小刻平视圆眼 | 环绕线按 0.86 缩放，留在 27pt 槽内 | 是 | 0.9 |
| `crew-permission` | alert 2.4 → idle 1.4 | 同上 | `glow` 琥珀慢呼吸（一个周期 3.8 s） | 是 | 1.6 |
| `crew-input` | idle 4.0 | bloub `confus` | 头歪 9°（4 s 周期）、±2.2° 抖动与 `glow` 青色快闪（周期 4/15 s ≈ 0.267 s，片段内恰 15 个整周期，循环处不跳） 、`?` 符号 | 是 | 2.0 |
| `crew-compacting` | burst 2.6 → thinking 1.2 | 平视 | 无 | 是 | 3.2 |
| `crew-done` | comet 2.4 → idle 1.8 | 平视，2.4 s 起笑眼 | `ring` 在 2.4 s 后 0 → 1 → 0（绿环闪一次） | 否，播一次 | 不用（减少动态时直接取 `crew-rest`） |
| `crew-rest` | idle 6.0 | 平视，眼皮全合 | 身体 ±1.5° 慢摆 | 是 | 0 |
| `crew-stale` | idle 5.0 | bloub `triste`，视线下压 | `lids` 0.5、身体 −5° 到 −7.5° 慢摆（55% 不透明是 `Style.opacity` 的事，片段不带） | 是 | 0 |

小刻的眼睛是平视圆眼：眼椭圆高不超过宽的 1.3 倍；所有几何变换（歪头、抖动、压扁、慢摆、第 7 版的 `dy`）在导出时烘进 `body`、`eyes.matrix`、`dots`、`arcs` 的坐标，原生端不做变换。每帧新增四个可空字段，老片段不写：

| 字段 | 类型 | 含义 |
|---|---|---|
| `glow` | number 0–1 | 身后径向光晕的不透明度；颜色不进文件，render 按片段名取：`crew-permission` 琥珀 `255,197,61`，`crew-input` 青 `125,227,247` |
| `ring` | number 0–1 | 描边与光晕叠一层品牌绿 `#60D880` 的不透明度 |
| `lids` | number 0–1 | 眼皮从上往下盖住眼睛的比例，用眼睛路径裁剪后填 `Style.lid` |
| `arcEyes` | bool | 真时眼睛画成白色弧线（笑眼 / 合眼），`eyes` 里的宽高矩阵照旧，弧线按它画 |

`dots` 里新增 `piece: true`：没有显式颜色也没有景深的碎片（`alert` 的「!」点、`thinking` 的两个侧点）是身体分出去的，按身体材质画；带景深的粒子仍是实心色点。导出脚本对所有片段统一打这个标记，老的 `compacting` 片段重采样后也带上，所以 AI 页压缩中的三点跟着变成小玻璃球（见「不做什么」）。

crew 片段采样 20 fps，老片段仍是 30 fps；`fps` 从文件级字段改成每个片段自带（`clips.<名>.fps`，老片段写 30），解码器按片段取。`crew-done` 不预跑循环（播一次），其余预跑一轮保住状态间形变。`export.cjs` 直接写回仓库的 `Resources/bloub/frames.json`（现在就是这样），预计从 2.9 MB 涨到 4.5 MB 以内；`build-app.sh` 不用改。

### 绘制（crew-render）

`BloubArt.Frame.draw(in:time:style:)` 增加 `style: BloubArt.Style`：

```swift
struct Style {
    enum Skin { case glass, gradient }
    var skin: Skin = .glass
    var rim: [Color] = BloubArt.rimColors      // 描边 / 光晕 / 环绕线 / 粒子的色系
    var fill: (Color, Color)? = nil            // 渐变套系的身体上下两色；glass 不用
    var lid: Color = Color(white: 0.11)        // 眼皮色
    var glow: Color? = nil                     // 帧里 glow > 0 时的光晕色；nil 不画
    var opacity: Double = 1                    // 整个角色的不透明度
}
enum CrewStyle {   // 纯函数：mood + 调色板 + 套系 → Style
    static func style(mood: CrewMood, palette: Int, skin: Style.Skin) -> Style
}
```

`CrewStyle.style` 定三件事：`glow` 只在 `permission`（琥珀 `#FFC53D`）和 `input`（青 `#7DE3F7`）给色；`opacity` 只在 `stale` 为 0.55；`stale` 的 rim / fill / lid 用 `ash`，其他按 `palette`。`draw` 本身不认识片段，只看 `Style` 和帧字段。调色板的值：

| 调色板 | rim（六色，首尾相同） | fill 上 → 下 | lid |
|---|---|---|---|
| 0 coral | `#FF7A3C #FF487A #FFB05C #FFE078 #FF6C54 #FF7A3C` | `#FFB36B → #FF6A5B` | `#FF8E63` |
| 1 peach | `#FFB347 #FF7A3C #FFE078 #FFF3B0 #FF9A4D #FFB347` | `#FFD66B → #FF8A4B` | `#FFAE58` |
| 2 rose | `#FF5C8A #FF8ABF #FFB36B #FFD1E8 #FF6C7A #FF5C8A` | `#FFA36B → #FF5C8A` | `#FF7E79` |
| 3 mint | `#2BC48A #8CF5D2 #4DEBFF #B8FFE8 #3BD6A0 #2BC48A` | `#8CF5D2 → #2BC48A` | `#5EDDAE` |
| 4 sky | 现有 `rimColors` | `#8FE8FF → #3B9CF5` | `#63C2FA` |
| 5 lime | `#5FCB63 #D6F77A #9BE16E #F3FFB0 #7ADB6A #5FCB63` | `#D6F77A → #5FCB63` | `#9BE16E` |
| ash | `#787E8C #969CAA #787E8C` | `#9AA1AE → #5B6270` | `#7A8290` |

AI 页和药丸的调用不传 `style`，除碎片材质这一条外画法不变。解码时 `dots` 的 `Fill` 多一个 `material: .solid | .body` 字段（`piece` 为真解成 `.body`），画的时候 `.body` 走身体材质例程（模糊光晕描边 → 近黑渐变填充 → 描边 → 裁剪内高光，高光锚在碎片自己的中心），`gradient` 套系下碎片同样用套系的两色渐变。六套调色板前三套暖、后三套冷（表见上）；`glass` 套系不用 `fill`，`lid` 恒为 `white: 0.11`；`gradient` 套系用表里的 `fill` 与 `lid`。

### 名册（crew-roster，纯函数）

```swift
// CrewMood 定义在 crew-render（CrewStyle.swift）：enum CrewMood: Int { case permission = 0, input, compacting, run, done, stale }，数字小的更急
struct CrewProject: Equatable, Identifiable {
    let id: String          // 项目键：canonicalize(cwd)，见下
    let name: String        // 最后一段；根目录是 "/"
    let sessions: [SessionRecord]   // 不含 ended，按 displayOrder
    let mood: CrewMood      // sessions 里最急的那个
    let palette: Int        // 0–5，id 的 FNV-1a 哈希 mod 6
    let providers: [String] // 去重后按首见顺序
}
struct CrewLayout: Equatable { let right: [CrewProject]; let left: [CrewProject]; let overflow: Int }
enum CrewRoster {
    static func projects(_ sessions: [SessionRecord], now: Date, canonicalize: (String) -> String = standardized) -> [CrewProject]   // 按 (mood, 最近 updatedAt 倒序)
    static func standardized(_ cwd: String) -> String   // 纯函数：NSString.standardizingPath + 去尾斜杠；调用方传入再加 resolvingSymlinksInPath 的版本
    static func layout(_ projects: [CrewProject], perSide: Int) -> CrewLayout
    static func newcomers(seen: Set<String>, current: [CrewProject], launchedAt: Date, now: Date) -> (badge: [CrewProject], seen: Set<String>)
}
```

状态折叠：每条会话先映射——`waitingPermission → permission`、`waitingInput → input`、`compacting → compacting`、`running → run`、`done` 且 `backgroundWork != nil → run`、`done → done`、`isStale(now:) → stale`（判在最前，与 AI 页「失联」同一函数）；`ended` 不进名册。项目 mood 取最小值。名册不看 `provider`：Codex 会话折不出 `input` / `compacting` 是 hook 数据层的事实（`docs/ai.md`），不在这里兜底。会话数 ≥ 2 时角色右下角画计数徽标。

槽位：右翼先填，离刘海近的槽给最急的项目；右翼满了填左翼，同样从近到远；项目数超过 `2 × perSide` 时左翼最外一格换成「+N」计数胶囊，N = 项目数 − (2 × perSide − 1)，即连被胶囊顶掉的那一个一起数（默认每侧 3 时 7 个项目显示 5 个角色加「+2」）。`perSide` 夹在 1–4。翼宽按实际占用的槽数算（角色数加胶囊），不按 `perSide`：一个项目时右翼只有 43pt。

新项目：`seen` 是本进程见过的全部项目 id（含启动头 10 秒内出现、没发过工牌的）；`newcomers` 把 `current` 里不在 `seen` 的 id 全部并进返回的 `seen`，其中 `now - launchedAt ≥ 10 s` 时出现的才进 `badge`。所以启动时成批出现的项目被记住但不发牌，之后也不会补发；`/clear` 换会话 id 不换目录，id 不变也不发。调用它的是 crew-badge 在 `CrewController.rosterChanged` 回调里（任务 7 才接上），`crewEnabled` 关着时不调。

### 翅膀（crew-panel）

- `CrewGeometry`（纯函数，输入 `ScreenMetrics` 与该翼实际占用的槽数）：槽宽 27、球身 22、翼内边距 8，翼宽 = 8 + 槽数 × 27 + 8；翼高 = `safeAreaTop`；右翼从物理刘海右缘起：x = `frame.width − auxiliaryTopRightWidth`，左翼到物理刘海左缘止：`maxX = auxiliaryTopLeftWidth`；y = `frame.maxY − safeAreaTop`。刘海面板闭合 frame 两侧各多出的 2pt 盖在翼上（面板级别更高），所以接缝处是面板的黑。外侧底角圆角 12（和闭合态一致），内侧直角。空翼（没有项目）不上屏。
- `CrewPanel: NSPanel` 属性照 `PillNotificationPanel`（非激活、`.mainMenu + 2`、同一组 `collectionBehavior`、无阴影、`canBecomeKey = false`）；级别比刘海面板低一级，比菜单栏（24）和状态项（25）高。内容是 `CrewStrip`（SwiftUI）：纯黑底 + 每槽一个 `Canvas` 画 `BloubArt` 帧。
- 动画时钟：`TimelineView(.animation(minimumInterval: 1/20, paused:))`；`paused` 在以下任一成立时为真——系统减少动态效果、`NSWorkspace.screensDidSleepNotification` 之后到 `screensDidWake` 之前、`sessionDidResignActive` 期间、面板展开或全屏隐藏（这两种翅膀本来就 `orderOut`）。低电量模式（`isLowPowerModeEnabled`，监听 `NSProcessInfoPowerStateDidChange`）把间隔放到 1/10。减少动态效果时每个角色取表里的静态帧时刻。
- `crew-done` 播一次：名册刷新时某项目从非 `done` 进入 `done`，该槽从 0 播 `crew-done` 到尾，然后切 `crew-rest` 循环；启动时就已是 `done` 的直接 `crew-rest`。其他 mood 变化重置该槽的时间原点，片段从头播。
- `CrewController`（`@MainActor`，`NotchController` 持有一个）：订阅 `SessionStore.sessionsChanged`，每次回调重算 `projects` / `layout`，更新两翼内容与 frame，然后触发 `rosterChanged: (([CrewProject]) -> Void)?`（crew-badge 订阅）；翼窗口的 `NSTrackingArea`（`.mouseMoved` + 进出）归它，光标进出哪个槽通过 `onHover: ((CrewHover?) -> Void)?` 回调出去（crew-bubble 设置），它不引用气泡类型。
- 接入点：`NotchController.relayout` 重算两翼 frame；`evaluateFullScreen` 藏 / 显；`applyPreferences` 同步 `sharingType`、读三个偏好键；`open()` 时 `orderOut`，`close()` 动画结束后 `orderFront`；`NotchPanel.steppingAside` 的类型过滤加 `CrewPanel`（任务 5），气泡窗口在任务 6 再加。
- 演示模式：`DemoData` 的会话改成六个不同目录、恰好覆盖六个 mood（等审批、等输入、压缩中、在跑、完成、失联，失联那条 `updated_at` 在 3 小时前），默认 3 + 3 正好放满、不溢出；`DemoModeTests` 里「没关闭的不失联」那条用例改成「恰有一条失联」。`--demo --crew-overflow` 多给两个在跑的项目（8 个），用来看「+3」胶囊；和 `--peek-test` 一样只在演示模式下认。

### 气泡与点击（crew-bubble）

- 槽位命中由 `CrewController` 上报（见上）；停 150 ms 显示气泡，离开槽和气泡 300 ms 后收起；在气泡里时不收。气泡固定住期间名册刷新把该项目拿掉了，气泡立即收起。
- `CrewBubblePanel` 和药丸同一类窗口属性（也加进 `steppingAside` 的类型过滤），宽 `min(300, 屏宽 − 32)`，位置由 `CrewGeometry.bubbleFrame(slot:…)` 算：挂在该角色正下方 6pt 处，贴屏幕边时向内推。第一行：项目名 · 状态文字（等审批 / 等输入 / 在跑 / 压缩中 / 完成 / 失联） · `N 个会话`（≥ 2 时）；只有一个会话时第二行是 `displayTitle`，多个会话时逐行列出：提供方标志、`modelLabel`（没有用 `providerLabel`）、状态、标题（中间截断），每行可点。
- 点击分派是纯函数 `CrewBubble.tap(project:slot:) -> CrewTap`（`.jump(SessionRecord)` / `.pin` / `.openAI`），执行层把 `.jump` 交给 `SessionJump.shared.run`、`.openAI` 交给注入的 `openAIPage` 闭包（`NotchController` 注入为 `open(pinned: true)` 并切 AI 页）、`.pin` 固定气泡显示列表（点气泡外或离开 1 s 才收），点某行再 `.jump`。气泡的显示状态机也是纯函数（`CrewBubble.State.reduce(event:)`，事件：进槽、离槽、进气泡、离气泡、点击、名册刷新），名册刷新后项目不在了就回 `hidden`。跳转失败的文案（`SessionJump.failures`）写进气泡对应行，红字，和 AI 页同一来源。
- 右键翅膀不弹 Tally 菜单（那是刘海的）。

### 工牌（crew-badge）

`Peek` 新增 `style = .badge`：图标是该项目调色板的 `crew-rest` 静态帧（28pt），标签「新项目」，标题是项目名，副标题 `providerLabel · modelLabel`（模型未知只写提供方），停留 `peekSessionSeconds`，点击按「点提示条时」设置处理（跳回那条会话 / 展开 AI 页 / 两者）。进队列的规则、三条并显、展开面板清空都照 `PillQueue` 现有规则；工牌按项目 id 去重，不走「同一会话新状态替换旧提示」那条。`--peek-test` 在第 0.5 秒先注入一张工牌（直接注入，不经 `newcomers` 的 10 秒规则），原来第 1 秒三条、第 2 秒一条不动，所以工牌是首批可见三条之一、第 1 秒的第三条排队。

### 设置（crew-settings）

`Preferences` 加三个键，`decodeIfPresent` 取默认：`crewEnabled: Bool = true`、`crewPerSide: Int = 3`（夹 1–4）、`crewSkin: String = "glass"`（只认 `glass` / `gradient`，别的回落 `glass`）。这三个键在构建顺序 4 就位，翅膀（顺序 5）读它们。设置窗口「面板」加一节「刘海小人」：开关「刘海两侧显示项目小人」、「每侧最多」1–4、「样式」黑玻璃 / 渐变；脚注一句：悬停看项目和会话，点一下跳回终端。关掉开关：两翼 `orderOut`、时钟停、不发工牌。

### 文档

新页 `docs/crew.md`（状态表、角色、翅膀、气泡、工牌、设置、验证），`docs/README.md` 索引加一行；`docs/panel.md` 「闭合态内容」改成「刘海本身不画，角色在独立的翅膀窗口里，见 crew.md」，「尺寸」表加翅膀一行；`docs/ai.md` 的 `SessionEyes` 段补一句碎片材质规则；`docs/monitors.md` 起停表加翅膀时钟一行；`Resources/bloub/README.md` 补七个片段与新字段。

## 任务与验证点

| # | 可独立验收的行为 | 文件或表面 | 可直接执行的验证命令 | 通过标准 |
|---|---|---|---|---|
| 1 | 七个小刻片段进 `frames.json`，解码器认新字段 | `Resources/bloub/export.cjs`、`frames.json`、`README.md`；`SessionEyes.swift` 的 `BloubArt` 解码 | 先按 `Resources/bloub/README.md` 的 clone + tsc 两步得到 `/tmp/tally-bloub-compiled`，然后 `node Resources/bloub/export.cjs /tmp/tally-bloub-compiled && stat -f %z Resources/bloub/frames.json && swift test --filter BloubArtCrewTests` | 文件 ≤ 4,800,000 字节；执行 ≥ 11 个用例全绿：七个片段都在且帧数 = 时长 × 20；六个循环片段首帧与末帧 body 路径最大点距 < 6（316 画布单位，球半径 100，22pt 下不到 0.5pt）；crew 片段每帧每只眼 `height ≤ 1.3 × width`；`crew-done` 的 `ring` 在 2.4 s 前恒为 0、之后峰值 ≥ 0.9；`crew-input` 的 `glow` 在任意 0.27 s 窗口内有升有降，且首帧与末帧的 `glow` 之差 < 0.1；`crew-stale` 每帧 `lids` = 0.5；`crew-rest` 每帧 `arcEyes` 为真；老 `compacting` 与 `crew-compacting` 的 thinking 段两个侧点都带 `piece`；`crew-permission` 的 alert 段的点带 `piece`；老的六个片段帧数、`fps` 30 不变，且 `git show HEAD:Resources/bloub/frames.json` 里每个老片段首帧的 `body` 数组与新文件逐值相等（容差 0.001，一行 python 比对；上游版本仍是 README 钉住的 `b4bb3c1b…`） |
| 2 | 同一个绘制函数按套系、调色板画角色，AI 页不传 style 时画法不变 | `SessionEyes.swift` 的 `BloubArt.Frame.draw`、`BloubArt.Style`；新文件 `CrewStyle.swift`（`CrewMood`、调色板表、`CrewStyle.style`） | `swift test --filter 'BloubArtCrewTests|QuotaBarRenderingTests'` | 新增用例 ≥ 5 全绿：`Style()` 默认值等于现有常量（rim 六色、glass、lid `white: 0.11`、glow nil、opacity 1）；六套调色板的 rim / fill / lid 与上表逐色相等，`ash` 单独；`piece` 为真的点解码成 `material == .body`、其余 `.solid`；`CrewStyle.style`：stale → opacity 0.55 且 rim 是 ash、permission → glow `#FFC53D`、input → glow `#7DE3F7`、其余 glow nil 且 opacity 1；现有 5 个 `QuotaBarRenderingTests` 仍绿。碎片材质的画面在任务 5 减少动态效果的那张图里看（压缩中静态帧取 3.2 s，正是三点：三个带描边的小球，不是实心色点） |
| 3 | 会话折叠成项目、排序、槽位、溢出、身份、新项目检测 | `Sources/Tally/Sessions/CrewRoster.swift`、`Tests/TallyTests/CrewRosterTests.swift` | `swift test --filter CrewRosterTests` | 执行 ≥ 14 个用例全绿：同目录两条会话一个项目；`/repo` 与 `/repo/`、符号链接后同目录合并，`/repo/sub` 不合并；`ended` 不进名册；折叠取最急（等审批 > 等输入 > 压缩 > 在跑 > 完成 > 失联），`done` + 后台算在跑，失联按 2 小时且不算完成；排序先 mood 后最近更新；右翼先满、左翼次之、两翼满时左翼最外格是 +N 且 N 正确；`perSide` 夹 1–4；同一路径的 palette 跨调用相同、六个不同路径至少命中 3 种；`newcomers`：启动 10 秒内出现的进 `seen` 不进 `badge`、之后只报不在 `seen` 的 id、同一 id 第二次调用不再报；`canonicalize` 默认版把 `/repo/` 与 `/repo/./` 归到 `/repo`，传入解析符号链接的闭包时链接与目标归到一起；`layout` 报出的每翼占用槽数含胶囊（7 个项目、每侧 3：右 3、左 3 其中一格是胶囊） |
| 4 | 三个偏好键进设置，可关可调 | `Preferences.swift`、`SettingsPage.swift`、`Demo/DemoData.swift`、`Tests/TallyTests/PreferencesTests.swift` | `swift test --filter PreferencesTests`；`rg -c 'crewEnabled' Sources/Tally/Preferences.swift Sources/Tally/Notch/SettingsPage.swift Sources/Tally/Demo/DemoData.swift Tests/TallyTests/PreferencesTests.swift` | 新增用例 ≥ 4 全绿：缺键取默认（true / 3 / glass）、`crewPerSide` 夹 1–4、`crewSkin` 非法值回落 `glass`、往返落盘一致；`rg -c` 四个文件计数都 ≥ 1；`open -a Tally --args --open settings` 后「面板」里能看到「刘海小人」一节三项（人看） |
| 5 | 闭合态刘海两侧出现角色，开关、全屏、截屏、屏幕变化、模态让路、减少动态效果都跟面板一致 | `Sources/Tally/Notch/CrewPanel.swift`（窗口与 `CrewStrip` 视图同文件，照 `PillNotificationPanel.swift` 的做法）、`CrewGeometry.swift`、`NotchController.swift`（五个接入点）、`NotchPanel.swift`、`Demo/DemoData.swift` | `swift test --filter 'CrewGeometryTests|NotchPanelTests|FullScreenDetectorTests|DemoModeTests'`；`./scripts/install.sh --build && pkill -x Tally; while pgrep -x Tally >/dev/null; do sleep 0.5; done; open -a Tally --args --demo && sleep 10 && screencapture -R456,0,600,40 -x /tmp/tally-crew.png && top -l 11 -s 1 -pid $(pgrep -n -x Tally) -stats pid,cpu \| awk -v pid=$(pgrep -n -x Tally) '$1 == pid {print $2}' \| tail -n 10 \| awk '{s+=$1} END {print s/NR}'`；再 `open -a Tally --args --demo --crew-overflow` 截一张；减少动态效果：先 `defaults read com.apple.universalaccess reduceMotion` 记原值，系统设置 → 辅助功能 → 显示 → 减弱动态效果打开后重启 Tally 截两张，验完 `defaults write com.apple.universalaccess reduceMotion -bool <原值>` 并在系统设置里核对一眼 | 几何用例 ≥ 6 全绿：14 寸 1512 / 663 / 664 / 32、占 3 格时右翼 frame = (848, 950, 97, 32)、左翼 = (566, 950, 97, 32)，占 1 格 43 宽，0 格返回 nil；`steppingAside` 把 `CrewPanel` 也压到 `.normal` 并还原；`CrewController` 在 `open()` 后两翼 `isVisible == false`、`close()` 后为真、`crewEnabled = false` 时两翼不存在（AppKit 测试用 `ScreenMetrics` 夹具，不依赖真机屏幕，和 `NotchPanelTests` 同一做法）；默认截图里刘海两侧各三个角色、六个状态肉眼可分（等审批是「!」形、等输入歪头带「?」、压缩中是三个带描边的小球、完成闭眼、失联灰），黑块与刘海无缝；`--crew-overflow` 截图里左翼最外是「+3」、角色 5 个；`awk` 打出的 10 个采样平均 ≤ 3（M 系列，第 1 个采样已丢；`top -l` 每轮前有一行日期，`$1 == pid` 只留进程行，按 `/^[0-9]/` 过滤会把「14:29:07」当 14 算进平均）；减少动态效果下间隔 2 秒的两张逐像素相同（`cmp` 返回 0）且翼区域内有白色眼睛像素（证明角色在图里；演示模式的设置本来就是截屏不隐藏） |
| 6 | 悬停出气泡，点击跳转或展开列表 | `Sources/Tally/Notch/CrewBubble.swift`、`NotchController.swift`（接 `onHover`、注入闭包）、`NotchPanel.swift`、`Tests/TallyTests/CrewBubbleTests.swift` | `swift test --filter CrewBubbleTests`；真机：`--demo` 下悬停右翼第一个角色 | 用例 ≥ 7 全绿：槽位命中按 x 算、首行文案三种（单会话 / 多会话 / 失联）、`tap` 单会话 → `.jump`、多会话 → `.pin`、+N → `.openAI`、气泡 frame 贴屏幕边时向内推、状态机在名册刷新后项目消失时回 `hidden`；真机：停 150 ms 出气泡、移到气泡上不收、离开 300 ms 收、多会话项目点一下列表固定、点列表行后气泡收起（demo 下跳转本身被挡是预期） |
| 7 | 新项目首次出现时弹工牌 | `PillQueue.swift`、`NotchController.swift`、`NotchView.swift`（`PeekIcon`）、`PillNotificationPanel.swift` | `swift test --filter PillQueuePeekTests`；真机：`open -a Tally --args --demo --peek-test` | 新增用例 ≥ 3 全绿：`.badge` 进队列、同会话规则不误伤（工牌按项目 id 去重，不按 sessionId 替换）、展开面板清掉；真机首批可见三条里有一张工牌（`--peek-test` 第 0.5 秒直接注入）：左侧角色静态帧、「新项目」标签、项目名、「Claude · Opus 5」 |
| 8 | 文档落地，全量回归，关掉开关后闭合态回到现状 | `docs/crew.md`、`docs/panel.md`、`docs/ai.md`、`docs/monitors.md`、`docs/README.md`、`Resources/bloub/README.md`、`.claude/CLAUDE.md` 与 `AGENTS.md`（只改 490 那个数，两份逐字同步）——全是文档，按仓库「改行为先改文档」的约定每个任务动手前先改对应段，这一任务只是收口核对 | `swift test`；`rg -n 'crew.md' docs/README.md docs/panel.md`；非演示模式、设置里关掉开关后 `screencapture -R456,0,600,40 -x /tmp/tally-crew-off.png`，看完把开关打开 | 全量测试全绿且用例总数 ≥ 565（基线 515 加任务 1–7 的最少新增 11+5+14+4+6+7+3 = 50，`swift test` 实测；`CLAUDE.md` 写的 490 已过时，顺手改掉）；`docs/panel.md` 设置表有三个键；关掉开关的截图里刘海两侧只有菜单栏、没有黑块（人看），且 AppKit 用例已证明两翼不存在（任务 5）；`rg` 两个文件都命中；`docs/panel.md` 「闭合态内容」不再说「什么都不画」而指向 crew.md |

## 预算与停止

连续 20 分钟没有新证据，或同一路径失败两次，停下报告并换方法；复审三轮仍有阻断项回到方案选型。真机 CPU 超过 3% 先降到 15 fps 再测，仍超就把光晕的模糊滤镜改成预烘的径向渐变，还超停下报告。翅膀和菜单栏状态项在用户机器上重叠到挡住常用图标，停下问用户是把每侧调到 2 还是换位置方案，不自己改默认值。用户同时在用这台机器和 `/Applications/Tally.app`：`install.sh --build` 攒到一个任务验收时装一次，截图完 `pkill -x Tally` 再 `open -a Tally` 换回非钉住、非演示的实例。

## Review Focus

1. 任务 3：会话目录含非 NFC 字符、带尾斜杠、符号链接指向同一处时的项目合并与 palette 稳定性。
2. 任务 5：合盖只剩外接屏 → 开盖回内建屏，两翼要跟着 `relayout` 回来且不留孤儿窗口；屏幕熄灭期间时钟确实停了。
3. 任务 5：面板展开动画 0.38 s 期间光标仍停在翅膀上，收起后翅膀回来时不能触发刘海面板的「刚收起 400 ms 内忽略进入」之外的重开。
4. 任务 6：气泡固定住时 `SessionStore` 刷新把该项目从名册里拿掉（会话结束），气泡要收起而不是指向已不存在的会话。
5. 任务 7：Tally 晚于一批会话启动，10 秒内成批出现的项目不发工牌；之后 `/clear` 换会话 id 但目录不变也不发。

## 影响面

- 调用方：`NotchController`（五个接入点）、`NotchPanel.steppingAside`、`PillQueue` / `Peek`、`DemoData`、`Preferences`；`SessionStore` 只多一个 `sessionsChanged` 的订阅者，会话文件契约不变。
- 依赖：仍零第三方；重建 `frames.json` 需要本机 Node + tsc（和现在一样，正常编译 app 不需要）。
- 兼容：老 `preferences.json` 缺三个键按默认，回滚后多出的三个键无害；`frames.json` 里缺 crew 片段时 `BloubArt` 照常解码老片段，只是 `crew` 不可用（翅膀不画，日志一条），AI 页照旧。重建 `frames.json` 的命令在 `Resources/bloub/README.md`，需要本机 Node + tsc，产物直接进仓库。
- 可观测：翅膀显隐、工牌、跳转失败走现有 `Log`。
- 菜单栏：翅膀窗口盖在菜单栏那一段之上（级别高于状态项），每侧最宽 4 格 124pt；默认 3 格时左翼压到 x = 566，右翼到 945，本机左边 WeChat 的菜单到 336、右边状态项从 1278 起，不冲突；菜单项多的 app（Xcode）或状态项多的机器会被盖住一两个，设置里调小「每侧最多」。
- 项目指令文件：任务 8 改 `.claude/CLAUDE.md` 与 `AGENTS.md` 各一处数字（490 → 实测数），两份逐字同步，不动别的行。
- 验证的副作用：任务 5、8 要重装并接管正在用的 Tally（仓库常规流程，不备份旧包；回滚是 `git checkout` 旧版再 `install.sh --build`）；任务 5 要临时打开系统「减少动态效果」、任务 8 要临时关 `crewEnabled`，做完都还原。`export.cjs` 覆写仓库里的 `frames.json`，老片段同参数重采样，git 里有旧版。
- 灰度与回滚：开关默认开；回滚是还原本 spec 涉及的文件并 `./scripts/install.sh --build`，`frames.json` 回到旧版即可，无数据迁移。
