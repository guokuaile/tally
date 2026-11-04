# 小刻角色池

## 问题

小刻现在只有一种长相：黑玻璃球。六个项目并排是六个一样的球，只靠状态动作区分，用户看腻了，AI 页会话行用的又是另一套六个会话片段（`working` / `permission` / …），同一个项目在刘海上和 AI 页里长得不一样。预览（`/Users/aiden/Desktop/digo-角色参考/tally-digo-preview.html`）已经定稿：角色池 = Digo 的十个位图角色 + 现有玻璃球，共 15 个；材质、流光、光晕、状态动作全部照 Tally 现有的 bloub 片段；角色的眼睛跟着 bloub 每帧的眼睛动，再叠一层角色自己的步态；AI 页行、提示药丸、工牌、悬停头像和刘海翅膀共用同一个角色。

不修的代价：角色辨识只能靠位置，多项目时找不到「我的那个」；两套动画数据与两套绘制入口（`SessionEyes` 与 `CrewBadgeIcon`）长期并存。

六行复述：

- **结果**：一个项目（工具 + 目录）从 15 个角色里稳定分到一个，刘海翅膀、AI 页会话行、提示药丸、工牌肖像、悬停头像都画这一个（指引窗口是静态示意图，没有项目，画池子里的前六个角色）；状态动作、配色、流光、光晕一字不改地沿用 `crew-*` 六个片段与 `CrewStyle`；角色的眼睛按 bloub 的眼睛矢量瞟、眨、瞪、半合、笑、随视线转，身体跟着 bloub 的形体位移、缩放、压扁（圆身的歪头在身体上看不出来，歪头只在眼睛上；失联那种身体本身微倾的跟着倾），再叠跳 / 晃 / 点头 / 飘 / 抖的步态。
- **用户**：本机跑多个 Claude Code / Codex 会话的开发者；日后拿到 DMG 的人要等素材授权解决后的版本。
- **为什么是现在**：预览已经过了四轮修改（反相入池、动画逐行移植、眼睛放大与步态加幅、羊重画），用户点头「没问题，开始落地」。
- **成功标准**：见「任务与验证点」；关键三条——演示模式六个项目在翅膀上是六个不同角色且 AI 页同项目的行是同一个角色；六个角色常驻 CPU 仍 ≤ 3%；`Resources/cast/` 缺失时退回只有玻璃球、功能不缺。
- **约束**：零第三方依赖；不改 hook 契约；bloub 的帧数据（`frames.json` 的 `crew-*` 六段）不改动画；角色素材是 Digo 的付费美术资产，授权未解决（见「影响面」，实施期间不发版）；翅膀的位图缓存键不能随时间无限增长；用户同时在用这台机器和 Tally，装包攒批只装一次。
- **不做什么**：见下一节。

## 不做什么

- 不改六个 `crew-*` 片段的时间线、表情、附加字段；不重新采样 bloub；`export.cjs` 里 crew 片段那一节一个字不动。
- 不做用户逐项目指定角色、不做角色设置项、不落盘角色分配：重启后同一项目靠散列大概率同一个角色，撞位才换。
- 不给角色做位图逐帧动画：角色只有一张位图、一条轮廓、两只眼睛的形状；所有动作来自 bloub 的帧和一条仿射步态。
- 不画 Digo 参考图里「听」以外的表情格；不做角色自己的表情表。
- 不改 `CrewStyle` 的配色与档位规则、不改名册的排序 / 槽位 / 溢出 / 工牌发牌规则。
- 不改已关闭会话行的三个静态点。
- 不改 `BloubArt.Style`。
- 不发版、不推公开快照、不出 DMG：素材授权解决前 `scripts/release.sh` 不跑，`build-dmg.sh` 见到素材又没有授权标记时自己拒绝打包（release-guard）。

## 方案选型

- **角色替换形体（选定）**：`BloubArt.Frame.draw` 多一个可选 `actor`：有角色时身体路径换成「角色轮廓 × 这一帧的仿射拟合 × 步态」，玻璃渐变填完后把角色位图裁在轮廓里以 `lighten` 混合画上去（白身原色版正常混合），流光描边、光晕、高光、环绕线、碎片、符号、绿环照旧；bloub 的眼睛不画，改按它每帧两只眼睛相对静止位的位移 / 缩放 / 旋转驱动角色自己的眼睛。没有眼睛的帧（等审批变「!」、压缩炸开、完成变彗星）直接画 bloub 的形体，角色「变回」玻璃球再变回来。代价：一个一次性的素材提取脚本、解码时按身体二阶矩算拟合。它错在：如果以后角色要有 bloub 做不出的姿势（挥手、转身），这条路给不了。
- 给每个角色重新采样 bloub 片段（拒绝）：bloub 的 skin 机制支持换形体，但 15 个角色 × 6 段 = 90 段，`frames.json` 从 1.5 MB 涨到 20 MB 以上，而且位图材质还是得在原生端叠，等于两头都做。
- 位图序列帧（拒绝）：把 Digo 的 GIF 拆成每角色每状态的 PNG 序列。没有流光描边与光晕的一致性（用户明确要 Tally 的外圈逻辑），15 × 6 × 90 张图体积失控，减少动态效果也没有对应的静态帧规则。

## 模块表

| id | 模块 | 职责 | 单向依赖 | 构建顺序 |
|---|---|---|---|---|
| cast-assets | `Resources/cast/export.swift`、`Resources/cast/cast.json`、`Resources/cast/*.png`、`Resources/cast/README.md`、`scripts/build-app.sh` | 从 Digo 参考图抠角色：轮廓、位图、眼睛、脸、步态种类、角色池顺序 | 无 | 1 |
| cast-render | `Sources/Tally/Notch/CastArt.swift`（新）、`SessionEyes.swift` 里的 `BloubArt`（`Frame` 加拟合与眼睛矢量、`draw` 加 `actor`、`init` 的硬要求改成六个 crew 片段） | 读 `cast.json` 与位图；每帧身体的仿射拟合；带角色的绘制 | cast-assets、`frames.json` | 2 |
| cast-roster | `Sources/Tally/Notch/CrewCast.swift`（新）、`CrewRoster.swift`（抽出 `projectKey(tool:path:)` 给名册和分配表共用） | 项目键 → 角色的分配（纯函数）与进程内分配表 | cast-render（`CastArt.pool`、`CastMember`）、`CrewRoster`（`tool(of:)`、`standardized`、`bucket`、`projectKey`）、`SessionRecord` | 3 |
| crew-wings | `CrewPanel.swift`（`CrewFrameCache.Key` / `Look`、`CrewController` 改用分配表与共用的目录规范化缓存）、`CrewDropdown.swift`、`GuideWindow.swift`、`NotchController.swift`（会话快照先喂分配表再喂名册） | 翅膀、悬停头像、指引图用角色 | cast-render、cast-roster | 4 |
| ai-rows | `SessionsPage.swift`、`NotchView.swift`（`CrewBadgeIcon`、`PeekIcon`）、`NotchController.swift`（`Peek.cast`）、`PillNotificationPanel.swift`、`SessionEyes.swift`（删 `SessionEyes` 视图与 `BloubArt.frame(mood:)`）、`Resources/bloub/frames.json`、`Resources/bloub/export.cjs`、`Resources/bloub/README.md`、两份测试 | AI 页行、药丸、工牌改用小刻片段与角色；删六个会话片段 | cast-render、cast-roster、crew-wings（`Peek.cast` 从分配表取） | 5 |
| cast-docs | `docs/crew.md`、`docs/ai.md`、`docs/README.md`、`NOTICE` | 文档与素材来源 | 无 | 6 |
| release-guard | `scripts/release.sh`、`scripts/build-dmg.sh` | 公开快照的树里不带 `Resources/cast/`；没有授权标记不打 DMG | 无 | 7 |

## 设计

### 素材（cast-assets）

`Resources/cast/export.swift` 是一次性工具（`swift Resources/cast/export.swift <sheet.png> Resources/cast`，用 CoreGraphics 读图，正常编译 app 不需要它），输入 Digo 的 `digo-faces-sheet@2x.png`：先校验像素尺寸恰为 2580 × 2640，不是就报错退出（别的图喂进来裁出来的是错格，但结构检查照样能过）；`README.md` 记这张图的 sha256。只取每个角色「听」那一格（230 × 230，中心 x 依次 301、545、786、1030、1274、1507、1748、1981、2225、2463，y = 298）。对每格：

1. 背景：从四边泛洪，alpha < 128 或亮度 ≥ 200 的像素算背景；丢掉面积不到最大块 8% 的碎块（参考图自带的 z / Z）。
2. 轮廓：沿像素边走出外轮廓，Douglas–Peucker ε = 1.0 简化，Chaikin 两轮平滑；按 `k = 200 / max(包围盒宽, 高)` 缩放、质心移到原点（bloub 单位：球直径 200）。
3. 眼睛：按亮度 128 分亮 / 暗两类做四连通分量；候选 = 不碰背景、面积在主体 0.15% 到 9% 之间、质心在上 80%、包围盒长宽比 ≤ 2.6、填充率 ≥ 0.5；成对条件 = 同类、|Δcy| < 0.15 H、|Δcx| > 0.1 W、面积比 ≤ 3，取面积和最大的一对。瞳孔 = 包在眼白包围盒里的异类分量（面积 ≥ 6 px）。肤色 = 眼睛外 2 到 5 px 环带像素的中位色；皮肤块 = 环带像素落得最多的分量。位图上把眼睛连瞳孔外扩 2 px 抹成肤色。
4. 眼睛放大系数 `scale`：目标眼高 = 身高 20%；封顶 2.2；两眼间距的 92% 除以眼宽；不超出所在皮肤块（各向用块边界到眼心的距离除以半宽 / 半高，再乘 0.95）。四者取小，不小于 1。
5. 脸：只对表里标了 `facePatch` 的角色（羊，1.3）：皮肤块的二阶矩拟合椭圆、放大 1.3；同时它的眼睛改成圆眼（眼白椭圆 w × max(h, 1.15 w)，瞳孔椭圆 0.48 w × 0.54 h，中心下移 0.06 h）。
6. 位图：230 × 230 RGBA PNG，背景透明；白身角色（羊、云、老电脑、文件夹、灯泡）另出一张逐像素取反的 `<名>-inverted.png`（羊不出：黑毛白脸像戴墨镜，用户否了）。

脚本对每个角色打印一行 `name=<名> eyes=<眼睛数> lum=<主体不透明像素亮度中位数> inverted=<反相版中位数或 ->`。角色不足两只眼睛、轮廓为空、白身角色反相后主体亮度中位数仍 ≥ 128，脚本都报错退出，不写文件。

输出 `cast.json`：

```json
{
  "version": 1,
  "pool": [["ball", false], ["cat", false], ["devil", false], ["soot", false], ["monitor", false], ["gamepad", false],
           ["cloud", true], ["mac", true], ["folder", true], ["bulb", true],
           ["sheep", false], ["cloud", false], ["mac", false], ["folder", false], ["bulb", false]],
  "characters": {
    "cat": {
      "label": "黑猫", "gait": "bounce", "whiteBodied": false,
      "outline": [0, -98.2, -40.1, 1, …, 3],
      "bitmap": { "x": -110.4, "y": -104.0, "size": 220.8 },
      "eyes": [
        { "cx": -31.2, "cy": -9.0, "w": 28.4, "h": 36.0, "scale": 1.0,
          "white": [0, …, 3], "pupil": [0, …, 3],
          "skin": "#1A1A1A", "whiteColor": "#F2F2F2", "pupilColor": "#1A1A1A" },
        { … }
      ],
      "face": null
    },
    "sheep": { …, "whiteBodied": true, "face": { "cx": 2.1, "cy": 6.0, "rx": 58, "ry": 40, "theta": 0.05, "color": "#1A1A1A" } }
  }
}
```

| 字段 | 类型 | 含义 |
|---|---|---|
| `pool` | `[[名, 反相]]` | 角色池顺序，下标就是散列的落点；第 0 个恒为 `ball`（玻璃球，没有位图与轮廓） |
| `characters.<名>.gait` | `bounce` / `sway` / `bob` / `float` / `tick` | 步态种类：猫、手柄跳；小恶魔晃；羊、刺球、文件夹点头；云、灯泡飘；老电脑、显示器抖 |
| `whiteBodied` | bool | 白身角色（羊、云、老电脑、文件夹、灯泡）；决定混合模式与是否有反相版 |
| `outline` | 路径 op 序列（和 `frames.json` 的 `body` 同一编码：0 move、1 line、2 cubic、3 close） | 角色轮廓，bloub 单位，质心在原点 |
| `bitmap` | `{x, y, size}` | 位图在角色坐标里的位置与边长（230 px 对应 `size`） |
| `eyes[i]` | 左眼在前（按 cx 排） | `cx, cy, w, h` 包围盒（角色坐标）；`scale` 放大系数；`white` / `pupil` 路径（角色坐标，`pupil` 可空）；三个颜色 `#rrggbb` |
| `face` | 椭圆或 null | 画在位图之上、眼睛之下的脸色块 |

反相版（`pool` 里第二项为 true）：位图用 `<名>-inverted.png`，`skin` / `whiteColor` / `pupilColor` / `face.color` 逐通道取 255 − c。

`scripts/build-app.sh` 把 `Resources/cast/cast.json` 和 `*.png` 复制到 `Contents/Resources/cast/`；没有这个目录也照常打包（见 cast-render 的退化）。`Resources/cast/` 下现有的三份 HTML（被否的早期预览，未跟踪）删掉。

### 绘制（cast-render）

**`CastArt`**（`CastArt.swift`，值类型 + 位图缓存）：

```swift
struct CastMember: Hashable { let name: String; let inverted: Bool; static let ball = CastMember(name: "ball", inverted: false) }
struct CastArt {
    struct Eye { let center: CGPoint; let size: CGSize; let scale: Double; let white: Path; let pupil: Path?; let skin, whiteColor, pupilColor: Color }
    struct Character { let gait: Gait; let whiteBodied: Bool; let outline: Path; let bitmapRect: CGRect; let eyes: [Eye]; let face: (path: Path, color: Color)? }
    enum Gait: String, Decodable { case bounce, sway, bob, float, tick }
    let pool: [CastMember]               // 文件缺失 / 解不开 / 校验不过时 [.ball]
    let characters: [String: Character]
    init(directory: URL)                 // 读 <directory>/cast.json；不失败，退化成只有球并记一条 Log.error
    static let bundled = CastArt(directory: Bundle.main.resourceURL!.appendingPathComponent("cast"))
    func bitmap(_ member: CastMember) -> CGImage?   // 懒加载、进程内缓存；ball 为 nil
}
```

`cast.json` 校验：`pool` 非空且第 0 个是 ball；每个被 `pool` 引用的角色都存在、`outline` 非空、`eyes.count == 2`、`bitmap.size > 0`、原色版与反相版各有对应 PNG 且 `CGImageSource` 能读出 230 × 230 的尺寸（只读属性不解码）；任一不满足整份作废，退回 `[.ball]` 并记日志。位图之后真解不出来（`bitmap()` 对非 ball 返回 nil）只画玻璃形体和眼睛，不崩。

**每帧的拟合**（解码时算，`BloubArt.Frame` 多两个字段）：

- `fit: Fit`（`cx, cy, theta, sx, sy`）：把 `body` 路径按曲线细分（每段三次曲线 12 份）后重采样成 240 个等弧长点，算质心与协方差；`theta = ½·atan2(2σxy, σxx − σyy)`，折到 (−45°, 45°] 并交换主次方差；各向异性 `a = |v1 − v2| / (v1 + v2)`，`theta` 乘以 `clamp((a − 0.02) / 0.06, 0, 1)`（接近正圆时主轴方向是噪声）；`sx = √(v1 / REF)`、`sy = √(v2 / REF)`，`REF` 是 `crew-run` 第 0 帧的各向平均方差。`BloubArt.init` 的硬要求改成六个 `crew-*` 片段：任一缺失或坏掉整份作废（AI 页和翅膀都靠它们）、作废前 `Log.error` 点名是哪个片段，多余的片段忽略；先解 `crew-run` 再解其余。
- `eyeSpecs: [EyeSpec]`（`center, size, rotation, alpha`，就是 `eyes[i].matrix` 拆出来的平移、`width × |(a, b)|`、`height × |(c, d)|`、`atan2(b, a)`），按 `center.x` 排序。现有的 `eyes: [Fill]` 保留给玻璃球。

**静止位**（常量，`CastArt.restEyes`）：左 (−32, −8)、右 (33, −8)，宽 30、高 36——`crew-run` 片段两只眼睛的中位数（实测 (−32.1, −7.5)、(32.95, −8.25)、30、36）；测试锁住它和真实中位数的偏差 ≤ 3 单位，`frames.json` 换了会报。

**步态**（`CastArt.gait(kind:phase:amp:) -> CGAffineTransform`，纯函数）：`phase = 帧号 / 片段帧数`（按帧号不按墙钟，所以位图缓存键不变、循环接缝处连续）；`amp` 按 mood：在跑 1、等审批 / 等输入 / 压缩中 0.5、完成 / 失联 0；减少动态效果（定格帧）0；`amp == 0` 恒为单位矩阵。bloub 单位：

| 种类 | 每轮周期数 | 变换 |
|---|---|---|
| bounce | 7 | `q = frac(7·phase)`，`s = sin(π q)`：translate(0, −14·amp·s + 6·amp·(1 − s))，scale(1 + 0.08·amp·(1 − s), 1 − 0.08·amp·(1 − s)) |
| sway | 2 | translate(10·amp·sin(4π·phase), −6·amp·sin(8π·phase))，rotate(7°·amp·sin(4π·phase)) |
| bob | 3 | `s = sin(6π·phase)`：translate(0, −8·amp·s)，scale(1 + 0.06·amp·s, 1 − 0.06·amp·s) |
| float | 2 / 1 | translate(0, −10·amp·sin(4π·phase))，rotate(5°·amp·sin(2π·phase)) |
| tick | 12 步 | `step = ⌊12·phase⌋ mod 2`：translate(0, −6·amp·step)，rotate((step == 1 ? 3° : −3°)·amp) |

**带角色的绘制**：`BloubArt.Frame.draw(in:time:style:actor:)`，`actor: CastActor?`（`CastActor` = 角色 + 位图 + `amp` + 帧号 / 帧数），为 nil 时和现在逐字一样。有角色时：

1. `morph = eyeSpecs.isEmpty`：没有眼睛的帧照画 bloub 形体与 bloub 眼睛（等审批的「!」、压缩炸开、完成的彗星），角色这几帧不出现。有眼睛但身体已经开始变形的过渡帧（等审批回球前后、完成缩点前后各几帧，`sx` 低到 0.2、各向异性到 0.6）角色跟着缩、压扁，和预览一致。
2. 否则 `M = translate(fit.cx, fit.cy) · rotate(fit.theta) · scale(fit.sx, fit.sy) · gait`，身体路径 = `outline.applying(M)`；`glass()` 里玻璃渐变填完之后、流光描边之前：裁到身体路径，把位图画在 `bitmapRect.applying(M)`；混合模式：`whiteBodied && !inverted`（白身原色，含羊）`normal`，其余（原黑身、白身反相）`lighten`——黑色让玻璃渐变透出来，白色部分盖住；接着描边、高光照旧。
3. 绿环、`face.clip(to: body)` 照旧；bloub 眼睛和 `notch` 不画，改画角色眼睛：对第 i 只眼（`eyeSpecs` 与 `eyes` 都按 x 排），`p = M⁻¹(center)`，`d = p − rest[i]`，`sx = (size.width / 30) / fit.sx`、`sy = (size.height / 36) / fit.sy`、`rot = rotation − fit.theta`，`gw` = 有瞳孔 0.5、没瞳孔 0.8；变换 = `M · translate(cx + d.x·gw, cy + d.y·gw) · rotate(rot) · scale(sx·scale, sy·scale) · translate(−cx, −cy)`，不透明度乘 `alpha`：`arcEyes` 时按眼白色描一道弧（弦 ±0.55 w、弓顶 −0.5 h、线宽 0.23 w、圆头）；否则填眼白，瞳孔裁在眼白里再平移 `d·(1 − gw)`，`lids > 0` 时裁在眼白里用肤色填 `(cx − w, cy − h/2, 2w, h·lids)`。脸色块在位图之后、眼睛之前画。`CastActor.eyeOffsets(frame) -> [CGPoint]` 把 `d` 暴露出来给测试。
4. 碎片、`notif`、符号、前环绕线照旧。

**尺寸**：翅膀 22pt（`CrewGeometry.scale` 不变，位图缓存 48 × 32pt @2x 不变）；AI 页行与药丸沿用现在的 316 单位画布映射（34pt 格里球身 21.5pt、28pt 药丸里 17.7pt），工牌 68pt 与悬停头像沿用 200 单位加 `inset`。

### 分配（cast-roster）

```swift
enum CrewCast {
    /// 项目键的 FNV-1a 落点（CrewRoster.bucket 同一个散列）
    static func slot(for key: String, poolCount: Int) -> Int
    /// 按首见顺序分：已分的不挪；新键取散列落点，占了就往后找第一个空位；池子满了直接用散列落点（允许重复）
    static func assign(order: [String], existing: [String: Int], poolCount: Int) -> [String: Int]
}
@MainActor @Observable final class CrewCastStore {
    static let shared = CrewCastStore()
    let art: CastArt                       // 默认 .bundled；测试注入
    private(set) var assigned: [String: Int] = [:]
    private var canonical: [String: String] = [:]   // cwd → 规范化目录；CrewController 的那份缓存挪到这里共用
    func canonicalize(_ cwd: String) -> String       // CrewRoster.standardized + resolvingSymlinksInPath，查缓存
    func key(provider: String, cwd: String) -> String   // CrewRoster.projectKey(tool: CrewRoster.tool(of:), path: canonicalize(cwd))，名册拼 id 用的是同一个函数
    func sync(_ sessions: [SessionRecord])  // 每份会话快照调一次：活会话（state != .ended）的键按首见顺序分，不活的键删掉
    func member(forKey key: String) -> CastMember       // 没分过的当场分（也进表），所以谁先问都一样
    func member(for session: SessionRecord) -> CastMember
}
```

- 分配表只有一张，以**活会话**为准，不看小人开关：`NotchController` 收到会话快照先 `sync`，再 `crew.refresh`、再发给页面（顺序写在 `sessionsChanged` 那一处）；翅膀、AI 页行、药丸、工牌、悬停头像都查这张表，同一个键在哪儿都是同一个角色。已关闭行不查（画三个点）。
- 同屏不撞：活项目 ≤ 15 个时两两不同；超过 15 个才可能重复。
- 演示模式不特殊处理：六个演示项目按同一规则分，截图里是六个不同角色。

### 翅膀、头像、指引（crew-wings）

- `CrewFrameCache.Look` 多一个 `cast: CastMember`，`Key` 多一个 `still: Bool`（定格帧步态为 0，和同一帧号的动态帧是两张图）；`image(_:scale:)` 按 `look.cast` 取 `CastActor`（ball 为 nil），`amp` 按 `look.mood`，`key.still` 时 0；`keep(_:)` 不变。
- `CrewController` 的 `canonical` 缓存删掉，改调 `CrewCastStore.shared.canonicalize`；`render()` 的 `looks` 带上角色；`CrewAvatarPanel` / `CrewMovingAvatar` 多一个 `cast`；`GuideWindow.stills()` 六个定格帧按 `pool` 的前六个角色依次画（球、猫、小恶魔、刺球、显示器、手柄），让指引图一眼看出角色不止一种。
- 20 fps 时钟、位图换 `contents`、CPU 预算不变。

### AI 页行、药丸、工牌（ai-rows）

- `CrewBadgeIcon` 多 `cast: CastMember`（没有默认值：每个调用点都得明说画谁，漏改的编译不过）与 `unit: CGFloat = 200`（316 给 34pt 行和 28pt 药丸）；`elapsed` 不为 nil 时按它选帧并开步态。
- AI 页 `StateIcon`：会话状态 → `CrewMood` 用名册同一条折叠规则（失联判在最前；`done` 且有后台工作 → run）；`ended` 仍画三个静态点；其余画 `TimelineView(.animation(minimumInterval: 1/20, paused: !visible || reduceMotion))` 里的 `CrewBadgeIcon(mood:, cast: store.member(for: session), size: 34, unit: 316, elapsed:)`，减少动态效果取 `CrewMood.still`。失联行按小刻规则画（灰、半合眼、3 秒一眨），不再 0.55 半透明；同项目的两行同一个角色、同一个相位。辅助功能标签不变。
- `Peek` 多 `cast: CastMember = .ball`，`NotchController` 造会话类 peek 时从 `CrewCastStore.shared.member(for:)` 取；`PeekIcon` 的 `.session` 画 `CrewBadgeIcon(mood: .done, cast:, size: 28, unit: 316, elapsed:)`，`.ask` 画 `.permission` / `.input`（按 `label == "等输入"`），`.badge` 的 `CrewBadgeIcon` 与工牌肖像（`PillNotificationPanel.badgePortrait`）都传 `peek.cast`。
- 删 `SessionEyes`（视图与 `Mood`）、`BloubArt.frame(mood:time:still:)`；`CrewController.init` 里的日志改成一条「frames.json 读不到或片段不全（原因见上一条日志）」。
- `Resources/bloub/export.cjs` 删掉会话六段的采样代码（`cycles` 表与 `sample` 函数那一节；crew 那一节不动），`frames.json` 只剩六个 `crew-*`（1 537 016 字节）；README 相应改写。
- `QuotaBarRenderingTests` 里两条 bloub 用例（等待表情的符号与眼睛、在跑的形体 / 环绕线 / 粒子）改到 `BloubArtCrewTests` 上按 `crew-permission` / `crew-input` / `crew-run` 验；`testBrokenCrewClipOnlyDropsThatClip` 改成「任一 crew 片段坏了整份为 nil」。

### 文档（cast-docs）

`docs/crew.md` 加「角色池」一节（池子、分配、素材字段、眼睛驱动、步态、退化）并把「边界」里「不做自定义形象」改成「不做用户指定角色」；`docs/ai.md` 的「会话行」动画段落改成指向 crew.md 的角色与片段；`docs/README.md` 的 crew 行提一句角色池；`NOTICE` 加 `Resources/cast/` 的来源行（Digo，付费资产，授权状态）。

### 发布闸（release-guard）

- `scripts/release.sh` 的快照树由新函数 `snapshot_tree` 算：临时索引（`GIT_INDEX_FILE`）读 `HEAD`，`git rm -r -q --cached --ignore-unmatch Resources/cast`，`write-tree`；`commit-tree` 和「树是否变了」的比对都用它。脚本多一个只读入口 `./scripts/release.sh --snapshot-tree`：只打印这棵树的哈希，不抬版本、不推、不打包，给测试用，和发版走同一个函数。
- `scripts/build-dmg.sh` 开头：`Resources/cast/cast.json` 存在而 `Resources/cast/LICENSE` 不存在就打印「角色素材授权未解决，不打包」退出 1。`LICENSE` 是授权标记，拿到授权（或换成自绘素材）时由用户放进去；`release.sh` 调 `build-dmg.sh`，所以发版同样被拦。本机 `install.sh` 不拦。

## 任务与验证点

| # | 可独立验收的行为 | 文件或表面 | 可直接执行的验证命令 | 通过标准 |
|---|---|---|---|---|
| 1 | 素材脚本从 Digo 参考图产出 `cast.json` 与 14 张位图，错图拒收；装包带上 | `Resources/cast/export.swift`、`cast.json`、`*.png`、`README.md`、`scripts/build-app.sh` | `rm -f Resources/cast/*.png Resources/cast/cast.json; swift Resources/cast/export.swift "/Users/aiden/Desktop/digo-角色参考/digo-faces-sheet@2x.png" Resources/cast > /tmp/cast-export.log; echo "export exit=$?"; python3 -I -c "import json,os,struct;d=json.load(open('Resources/cast/cast.json'));assert len(d['pool'])==15 and d['pool'][0]==['ball',False];c=d['characters'];assert len(c)==10 and all(len(v['eyes'])==2 and len(v['outline'])>20 for v in c.values());p=[f for f in os.listdir('Resources/cast') if f.endswith('.png')];assert len(p)==14,p;assert all(struct.unpack('>II',open('Resources/cast/'+f,'rb').read(24)[16:24])==(230,230) for f in p);print('ok')"; rg -c 'eyes=2' /tmp/cast-export.log; rg -n 'inverted=' /tmp/cast-export.log \| rg -v 'inverted=(-\|[0-9]\|[0-9][0-9]\|1[01][0-9]\|12[0-7])$'; swift Resources/cast/export.swift Resources/cast/cat.png /tmp/cast-wrong; echo "exit=$?"; ./scripts/build-app.sh && ls build/Tally.app/Contents/Resources/cast/cast.json` | `export exit=0`；打印 `ok`；`eyes=2` 计数 10；反相中位亮度那条 `rg -v` 无输出（四个反相版都 < 128）；错图 `exit` 非 0；包里有 `cast.json`。角色切对了格、眼睛抠对了位置靠任务 2 的条带图肉眼看 |
| 2 | 原生能读素材、算拟合、画带角色的一帧；素材缺失或缺图退回玻璃球 | `CastArt.swift`、`SessionEyes.swift`（`BloubArt`）、`Tests/TallyTests/CastArtTests.swift` | `swift test --filter CastArtTests 2>&1 \| tail -3; open "$TMPDIR/cast-strip.png"` | 末行 `with 0 failures`、用例数 ≥ 12（`Resources/cast/cast.json` 不存在时整组 `XCTSkip`，公开快照里跑测试不红）。用例：池 15、第 0 个 ball；10 个角色各 2 眼、轮廓包围盒长边 ∈ [196, 204]；`crew-run` 第 0 帧 `sx, sy ∈ [0.98, 1.02]`、`\|theta\| ≤ 0.01`；`crew-stale` 第 0 帧 `\|theta\| ≥ 0.03`（身体微倾）；`crew-input` 某帧 `cx ≥ 10`（头往旁边滑）；`crew-done` 某有眼帧 `sx ≤ 0.3`（缩点前）；`restEyes` 与 `crew-run` 眼睛中位数偏差 ≤ 3；`eyeOffsets`：`crew-run` 第 0 帧两眼 `\|d\| ≤ 3`、第 30 帧两眼 `d.x ≥ 20`（瞟右）；`gait` 五种在 `amp 0` 为单位矩阵、`phase 0` 与 `phase 1` 相等（接缝）、bounce `phase 0, amp 1` 的 `ty == 6`；`crew-stale` 第 0 帧和 `lids == 1` 的帧渲染成 48 × 32@2x 位图后像素不同，且第 0 帧有白色像素；`crew-permission` 第 5 帧（有眼）与第 6 帧（无眼）渲染不崩且位图不同；猫在 `crew-run` 第 18 帧 `amp 1` 与 `amp 0` 渲染的位图不同（定格帧没有步态）；指向不存在目录、只删掉 `cat.png` 的副本、`pool` 里塞了 `["ghost", false]` 的副本，三种都 `pool == [.ball]`；测试把 15 个角色各一帧 68pt 画成一条 `$TMPDIR/cast-strip.png`，肉眼核对每个角色切对了格、眼睛在脸上 |
| 3 | 分配纯函数与进程内分配表 | `CrewCast.swift`、`Tests/TallyTests/CrewCastTests.swift` | `swift test --filter CrewCastTests 2>&1 \| tail -3` | 末行 `with 0 failures`。用例：`store.key(provider:cwd:)` 等于 `CrewRoster.projects([同一条会话])` 返回的 `id`（翅膀和 AI 页不可能拿到两个键）；6 个键两两不同；再加第 7 个前 6 个不变；删掉一个再加回（无撞位）同一角色；16 个键能返回且前 15 个两两不同；`member(forKey:)` 没分过的当场分且第二次问得到同一个；`sync` 后不活的键从表里消失；`key(provider:cwd:)` 对 `/a/b/` 与 `/a/b` 同键、`claude` / `codex` 不同键、`mktemp -d` 的目录与指向它的符号链接同键 |
| 4 | 翅膀上六个项目六个不同角色，悬停头像与指引图同角色 | `CrewPanel.swift`、`CrewDropdown.swift`、`GuideWindow.swift`、`NotchController.swift` | `swift test --filter 'BloubArtCrewTests\|CrewRosterTests\|CrewExpandTests\|CastArtTests\|CrewCastTests' 2>&1 \| tail -3; ./scripts/install.sh --build && pkill -x Tally; while pgrep -x Tally >/dev/null; do sleep 0.5; done; open -a Tally --args --demo && sleep 12 && screencapture -R500,0,520,32 -x /tmp/tally-crew.png && P=$(pgrep -n -x Tally); top -l 31 -s 1 -pid $P -stats pid,cpu \| awk -v pid=$P '$1 == pid {print $2}' \| tail -n 30 \| sort -n \| sed -n 15p` | 末行 `with 0 failures`；截图里六格六个不同轮廓、六个状态仍肉眼可分（「!」、「?」、三小球、彗星、灰）；CPU 中位数 ≤ 3。`CastArtTests` 里 `CrewFrameCache` 用例：猫 `crew-run` 第 18 帧 `still: true` 与 `still: false` 两张图不同。肉眼两步：按 `docs/crew.md`「验证」悬停 shop-web 那格，探出的头像和格里是同一个角色；设置窗口打开指引，图里六个小人是球、猫、小恶魔、刺球、显示器、手柄 |
| 5 | AI 页行、药丸、工牌和翅膀同一个角色；`SessionEyes` 删除；会话片段删除 | `SessionsPage.swift`、`NotchView.swift`、`NotchController.swift`、`PillNotificationPanel.swift`、`SessionEyes.swift`、`Resources/bloub/frames.json`、`export.cjs`、`README.md`、`BloubArtCrewTests.swift`、`QuotaBarRenderingTests.swift` | `rg -n 'SessionEyes' Sources Tests; python3 -I -c "import json,os;k=sorted(json.load(open('Resources/bloub/frames.json'))['clips']);assert k==['crew-compacting','crew-done','crew-input','crew-permission','crew-run','crew-stale'],k;assert os.path.getsize('Resources/bloub/frames.json')<2000000;print('ok')"; swift test 2>&1 \| tail -3; ./scripts/install.sh --build && pkill -x Tally; while pgrep -x Tally >/dev/null; do sleep 0.5; done; open -a Tally --args --demo --open ai && sleep 15 && screencapture -R256,0,1000,560 -x /tmp/tally-usage.png; pkill -x Tally; while pgrep -x Tally >/dev/null; do sleep 0.5; done; open -a Tally --args --demo --peek-test && sleep 3 && screencapture -R560,0,760,430 -x /tmp/tally-badge.png` | `rg` 无输出；打印 `ok`；`swift test` 全绿；AI 页 mobile-app 两行同一角色、shop-web 行与任务 4 截图里翅膀上 shop-web 同一角色；首批三条提示里会话类药丸的图标与工牌肖像都是对应项目的角色（和 AI 页同名行比） |
| 6 | 文档是唯一依据 | `docs/crew.md`、`docs/ai.md`、`docs/README.md`、`NOTICE`、`Resources/cast/README.md` | `rg -n 'SessionEyes\|六个会话片段\|会话六个片段' docs/*.md; rg -c '角色池' docs/crew.md; rg -c '角色池' docs/README.md; rg -n 'Resources/cast' NOTICE; rg -n 'sha256' Resources/cast/README.md` | 第一条无输出；后四条各 ≥ 1 |
| 7 | 公开快照不带素材；没有授权标记不打 DMG | `scripts/release.sh`、`scripts/build-dmg.sh` | `T=$(./scripts/release.sh --snapshot-tree); echo "tree=$T"; git ls-tree -r --name-only "$T" \| rg -c '^Resources/cast/'; git ls-tree -r --name-only "$T" \| rg -c '^Sources/Tally/'; ./scripts/build-app.sh >/dev/null && ./scripts/build-dmg.sh; echo "dmg exit=$?"; ls build/*.dmg 2>/dev/null` | `tree=` 后面是 40 位哈希；`Resources/cast/` 计数无输出（0）；`Sources/Tally/` 计数 ≥ 30；`dmg exit=1` 且没有 dmg 文件。整条 `release.sh` 不跑 |

基线：任务 2、3 的测试文件不存在，命令现在失败；任务 5 的 `rg` 现在有 7 处命中、键是 12 个、文件 4 428 515 字节；任务 6 第一条现在命中 `docs/ai.md`；任务 7 的 `--snapshot-tree` 现在不认识（脚本先查工作区干不干净就退出）、`build-dmg.sh` 现在能打出 dmg。

## 预算与停止

- 任务 1 的提取脚本调参（眼睛检测、羊的脸）不超过 3 轮；第 3 轮仍有角色眼睛数 ≠ 2 就停下来报告，由用户定是否把那个角色移出池子（移出则任务 1–3 里的个数标准同步改，不自行改）。
- 同一验证命令连续失败两次换做法；20 分钟没有新证据停下来报告。
- 任务 4 的 CPU 超 3% 先查缓存键是否随时间增长（`CrewFrameCache.count` 在六个项目稳定 10 秒后应 ≤ 6 × 120），再查位图绘制是否落在每 tick 上。
- 真机验证攒批只装一次（任务 4、5 各一次），每批验完 `pkill -x Tally` 再 `open -a Tally` 换回非演示实例；用户同时在用这台机器。
- 复审三轮仍有阻断项回到方案比较。
- 整个实施期间不跑 `scripts/release.sh`。

## Review Focus

| 输入或失败模式 | 任务 | 验证 |
|---|---|---|
| `cast.json` 存在但有角色缺 PNG、`pool` 引用了不存在的角色 | 2 | 任务 2 用例「只删掉 `cat.png` 的副本 → `pool == [.ball]`」，再加一条 `pool` 里塞 `["ghost", false]` 的副本同样退化 |
| 活项目超过 15 个 | 3 | 任务 3 用例「16 个键能返回且前 15 个两两不同」 |
| 减少动态效果下的定格帧（步态为 0、角色不跳） | 4 | 任务 4 装包后按 `docs/crew.md`「验证」减少动态效果那条再跑一次：两张间隔 2 秒的翼区截图 `cmp` 返回 0 且翼里有白色眼睛像素 |
| 公开快照（没有 `Resources/cast/`）上跑 `swift test` | 2 | `CastArtTests` 整组 `XCTSkip`；`BloubArtCrewTests` 不依赖素材照常跑；本机验法：把 `Resources/cast` 临时改名再 `swift test --filter CastArtTests`，输出含 `skipped` 且 0 failures |
| 没有眼睛的帧与有眼睛的帧交界处 | 2 | 任务 2 用例「`crew-permission` 第 5 帧与第 6 帧」；肉眼在任务 4 截图流程里看等审批那格回球那一下 |

## 影响面

- **调用方**：`CrewBadgeIcon` 多两个带默认值的参数，现有调用不改也编译；`Peek` 多一个带默认值的字段；`BloubArt.Frame.draw` 多一个带默认值的参数；`CrewFrameCache.Look` 多一个字段，`init` 调用处要补。
- **删除**：`SessionEyes`、`BloubArt.frame(mood:time:still:)`、`frames.json` 六个会话片段（git 里能找回）、`export.cjs` 的会话采样。`Resources/cast/*.html`（三份被否的预览）未跟踪、删了找不回，不在任何验证命令里，用户单独点头才 `rm`；没点头就留着，它们不影响构建和打包。
- **兼容**：设置项不变；`frames.json` 老文件（带会话片段）照样能解（多余片段忽略）；没有 `cast/` 目录的旧包退回玻璃球；首次升级后每个项目的角色从球变成池子里的某一个，没有「之前的角色」要保。
- **可观测**：`cast.json` 读不到 / 校验不过一条 `Log.error`；`frames.json` 读不到一条（已有）。
- **回滚**：代码与素材一次提交，回滚就是 revert；素材目录删掉不影响运行。
- **素材授权（未决，由用户定）**：Digo 的十个角色是付费美术资产（参考图上每个角色标价 1.99 美元），Tally 的 DMG 会发给别人、公开仓库按树快照同步。本 spec 的闸有三道：公开快照不带 `Resources/cast/`、`build-dmg.sh` 没有 `Resources/cast/LICENSE` 就拒绝打包（任务 7，两道都是脚本自己拦）、实施期间不跑 `release.sh`。拿到授权或换成自绘素材时放进 `LICENSE` 才解开。
