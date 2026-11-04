# bloub 小刻片段

`frames.json` 来自 [jeremy-prt/bloub](https://github.com/jeremy-prt/bloub) 的纯函数动画引擎，固定版本 `b4bb3c1b5f93c7b87a2e8d620f667c4093d97749`，MIT 许可全文见 `LICENSE`。原项目的形象设计权利说明仍适用。

`frames.json` 的结构是 `clips.<片段名>.{fps, frames}`，只有刘海小人（小刻）的六个片段（`crew-run` / `crew-permission` / `crew-input` / `crew-compacting` / `crew-done` / `crew-stale`），20 fps，约 1.5 MB；AI 页会话行、提示药丸、工牌画的也是这六段（`docs/crew.md`「角色池」），没有另外的会话片段。片段的时间线、表情与附加字段见 `docs/crew.md`「片段」；几何变换（歪头、压扁、慢摆、下移）和眼神在导出时烘进 `body`、`eyes.matrix`、`dots`、`arcs` 的坐标，原生端不做变换；小刻的眼睛是平视圆眼，眼高封顶为眼宽的 1.3 倍；坐标只留一位小数（22pt 下 0.01pt）。

原生绘制适配深色面板：透明背景、带灰色反光的近黑主体、白色眼睛；主体外圈、环绕线与粒子按状态配色（`CrewStyle`），外圈随轮廓形变并带柔光；已关闭会话使用原生静态三个点，不采样 sleep 动画。原生 Canvas 读取矢量数据，不运行 JavaScript，也不依赖网页组件。Digo 位图角色的身体按每帧 `body` 的二阶矩拟合、眼睛按 `eyes.matrix` 驱动，见 `docs/crew.md`「角色池」。

每帧可空字段：`glow`（身后光晕不透明度，颜色由原生按状态取）、`ring`（描边叠品牌绿的不透明度）、`lids`（眼皮从上往下盖住的比例）、`arcEyes`（眼睛画成白色弧线）。`dots` 里没有显式颜色也没有景深的点标 `piece: true`（`alert` 的「!」点、`thinking` 的两个侧点）：它们是身体分出去的，原生按身体材质画，带景深的粒子仍是实心色点。

重建（需要本机 Node 与 TypeScript；正常编译 app 不需要）：

```sh
git clone https://github.com/jeremy-prt/bloub /tmp/tally-bloub-reference
git -C /tmp/tally-bloub-reference checkout b4bb3c1b5f93c7b87a2e8d620f667c4093d97749
tsc /tmp/tally-bloub-reference/src/bot/engine.ts /tmp/tally-bloub-reference/src/bot/skins.ts /tmp/tally-bloub-reference/src/bot/expressions.ts --module commonjs --target es2022 --skipLibCheck --outDir /tmp/tally-bloub-compiled
node Resources/bloub/export.cjs /tmp/tally-bloub-compiled
```

`scripts/build-app.sh` 把 `frames.json` 和 `LICENSE` 复制到应用的 `Contents/Resources/bloub/`；脚本目录按仓库约定不纳入 Git，换机器需保留这两行资源复制步骤。
