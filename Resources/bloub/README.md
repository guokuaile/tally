# bloub 会话表情

`frames.json` 来自 [jeremy-prt/bloub](https://github.com/jeremy-prt/bloub) 的纯函数动画引擎，固定版本 `b4bb3c1b5f93c7b87a2e8d620f667c4093d97749`，MIT 许可全文见 `LICENSE`。原项目的形象设计权利说明仍适用。

各状态复用原版轮廓、形变、环绕线的前后遮挡、粒子及眼神。原生绘制适配深色面板：透明背景、带灰色反光的近黑主体、白色眼睛；主体外圈、环绕线与粒子统一为视频参考里的青蓝紫粉色系，外圈随轮廓形变并带柔光；已关闭会话使用原生静态三个点，不采样 sleep 动画。按原项目时长选择 `play → orbit → idle`、`burst → thinking`、`wink → idle` 等循环，采样 30fps；循环前预跑一轮，以保留原引擎的状态间形变。等审批用 `notify → wide` 和蓝点跳动；等输入用已有 `egg → hexagon`。等待循环各 4 秒，角色、眼睛与外圈全程连续；导出符号类型与主体位移，原生在右上方绘制倾斜约 18° 的浅青 → 粉白 → 浅紫渐变的 `!` / `?`，符号持续显示、随角色轻弹和微摆，不替换眼睛。等待角色整体缩至 90%，左移 8、下移 8（316 单位画布），符号位置与大小不变，为符号与光圈留出间隙。符号字号为 148.4，放大 40%。审批提示点位于左上沿，半径缩小至 14–17 单位，保留青蓝渐变，避免挤占符号位置。减少动态效果使用角色加右上符号的静态帧。原生 Canvas 读取矢量数据，不运行 JavaScript，也不依赖网页组件。

`frames.json` 的结构是 `clips.<片段名>.{fps, frames}`，采样率每个片段自带：会话六个片段（`working` / `permission` / `input` / `compacting` / `happy` / `stale`）30 fps，刘海小人（小刻）六个片段 20 fps。小刻片段的时间线、表情与附加字段见 `docs/crew.md`「片段」；几何变换（歪头、压扁、慢摆、下移）和眼神在导出时烘进 `body`、`eyes.matrix`、`dots`、`arcs` 的坐标，原生端不做变换；小刻的眼睛是平视圆眼，眼高封顶为眼宽的 1.3 倍；小刻坐标只留一位小数（22pt 下 0.01pt），会话片段三位。

每帧可空字段（会话片段不写）：`glow`（身后光晕不透明度，颜色由原生按状态取）、`ring`（描边叠品牌绿的不透明度）、`lids`（眼皮从上往下盖住的比例）、`arcEyes`（眼睛画成白色弧线）。`dots` 里没有显式颜色也没有景深的点标 `piece: true`（`alert` 的「!」点、`thinking` 的两个侧点）：它们是身体分出去的，原生按身体材质画，带景深的粒子仍是实心色点；会话片段重采样后同样带这个标记，所以 AI 页压缩中的三点也是小玻璃球。

重建（需要本机 Node 与 TypeScript；正常编译 app 不需要）：

```sh
git clone https://github.com/jeremy-prt/bloub /tmp/tally-bloub-reference
git -C /tmp/tally-bloub-reference checkout b4bb3c1b5f93c7b87a2e8d620f667c4093d97749
tsc /tmp/tally-bloub-reference/src/bot/engine.ts /tmp/tally-bloub-reference/src/bot/skins.ts /tmp/tally-bloub-reference/src/bot/expressions.ts --module commonjs --target es2022 --skipLibCheck --outDir /tmp/tally-bloub-compiled
node Resources/bloub/export.cjs /tmp/tally-bloub-compiled
```

`scripts/build-app.sh` 把 `frames.json` 和 `LICENSE` 复制到应用的 `Contents/Resources/bloub/`；脚本目录按仓库约定不纳入 Git，换机器需保留这两行资源复制步骤。
