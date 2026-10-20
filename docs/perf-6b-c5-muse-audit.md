# C5 / Muse 报告验收（2026-10-20）

> 对象：`part-ac-code-page-parity.md`（sbx `/home/ubuntu/wiring/docs/`，本地 `/home/ubuntu/aa-test/part-ac-code-page-parity.md`）。
> 方法：不读结论下判断；用 sbx 上的同一套工具（`q.py --exact-only --drop-shared`、`dis1.py`、二进制常量直读）抽样复现关键 EVIDENCE，再做反证检查与交叉对照。

## 1. 抽样复现结果（全部通过）

| 抽验点 | Muse 声明 | 复现命令/手段 | 结果 |
|---|---|---|---|
| M1 调用图 | `0x102735628` 的 caller = dispatcher `0x1027291b8` + `0x102737174` | `q.py --callers 0x102735628 --exact-only --drop-shared` | ✅ 一致（2 callers） |
| M1 调用点 | `0x10272a9c4: bl 0x102735628` | `dis1.py 0x10272a9c0` | ✅ 指令一致 |
| M2 blockSpacing | 默认 16.0，`0x10170a9c4–cc` 写字段 | `dis1.py 0x10170a9c0` | ✅ `mov x9,#0x4030…` = 16.0，`str x9,[x19,x8]` |
| M2 interBlockSpacing | `.some(0.0)`（修正 part-ab 的 nil） | `dis1.py 0x102b4b1a0` | ✅ `str xzr,[x8,#8]`（payload 0.0）+ `strb w9,[x8,#0x10]`（tag=some）；紧接 `0x4024…` = 10.0（interMessageSpacing） |
| M3 firstLineHeadIndent | 恒 0.0，`0x1016fe0e0` | `dis1.py 0x1016fe0dc` | ✅ `bl` 后 `ldp x8,x9,[x21,#0x10]`（listLevel 读数）位置吻合，setter 序列与报告一致 |
| M4 圆角 | 24.0，常量 `0x1042cba70` | 二进制 fileoff 直读 double | ✅ = 24.0 |
| M4 header 高 | 44.0 `ScaledMetric`，`0x100a4ef0c` | `dis1.py 0x100a4ef08` | ✅ 函数边界吻合（`0x100a4ef0c` 起函数头，`0x4046…` 常量在 init 链内，未见矛盾） |

## 2. 反证检查

- **M1**：主动找反例——是否存在“同一 message ID 拆成多个 DisplayMessage”的路径。`0x102737174` 不调 processor（Muse 已证），`0x10272fa48` 操作的是 `pendingResultAttachments`（Muse 标 INFERENCE，合理）；未发现反例。
- **M2**：`interBlockSpacing = .some(0.0)` 是对 part-ab 的修正；我复核指令 `str xzr`（payload 0.0）+ `strb 1`（tag .some）确实成立，part-ab 当时是类型推断，Muse 的指令级读数更硬。
- **M4**：`display` 写入值 = `MarkdownCodeTextView.self` 仍是强 INFERENCE（Scene 级写入类型 + 全二进制唯一 conformer），Muse 没有拔高成 EVIDENCE，分档诚实。

## 3. 交叉对照（与 Hark part-ab / part-aa）

- 一致：行粒度、表格复用、流式行结构、`CodeTextDisplay` 唯一实现。
- Muse 修正 part-ab 两处（interBlockSpacing、theme 三处分工），均有指令依据，采纳。
- 无互相矛盾但都无地址的悬空结论。

## 4. 质量评级

| 题 | 评级 | 理由 |
|---|---|---|
| M1 | **A** | EVIDENCE 链完整可复现；INFERENCE 项（`0x10272fa48` 字段归属）分档正确；UNKNOWN 写了下一步指令 |
| M2 | **A−** | 16.0 / 0.0 / 10.0 / 4.0 全部指令级；`rowMargins`/`padding.bottom` 承认运行时动态、标 UNKNOWN，没有编数值 |
| M3 | **B+** | 9 个 setter + 公式结构 + 24.0/0.6/1.0/2.0 是硬证据；但 marker 机制、切块粒度、引用条几何缺 → 复现公式给不出（诚实） |
| M4 | **A−** | 圆角/背景/边框/header/展开 sheet/复制纯文本全可复现；divider 颜色、字体行距仍 UNKNOWN |
| M5 | **B** | “tool 不在流式行”有类型字段证据；keypath/时序仍 INFERENCE/UNKNOWN |

**总评：B+，可作为实现依据的 A/A− 项（M1、M2 数值、M4 卡片常量、M5 的“tool 不在流式行”）足够开工；M3 剩余项不阻塞列表/引用的现状。**

Muse 做逆向工作没问题：工具使用规范（`--exact-only --drop-shared`）、分档纪律（没把 INFERENCE 写成 EVIDENCE）、产出结构（五条结论 + 地址 + UNKNOWN 下一步）都合格，且诚实报告了“复现公式给不出”。

## 5. 由此确定的 AA 改动方向（下一张任务单的输入）

1. **tool call 并回消息 cell**（M1 EVIDENCE）：官方 tool call 是 `DisplayMessage.blocks` 的兄弟块。这会动 AA 的 `.tools` group 分组模型，单独出任务单，先审后做。
2. **间距数值**（M2 EVIDENCE）：内层 Markdown 块间距 12 → **16**；外层消息内块间距（DisplayMessage.blocks 层）按官方 **0.0** 语义重新映射 AA 的 stack spacing；消息间 10.0 作候选。`rowMargins` 不硬编码。
3. **代码卡片常量**（M4 EVIDENCE）：圆角 23 → **24 continuous**、header 22 → **44**（ScaledMetric）、背景/边框色改官方值（AA 现值 `codeCardFill`/`codeCardBorder` 亮色已同、暗色一致；边框亮色 `0xD5D5D1` vs 官方 sRGB(0.118,0.118,0.114)@30% 需换算成不透明等效或直接用 30% alpha）；展开改 sheet。
4. **M3 列表/引用不动**；等下一轮（`T[idx_c]`、marker、切块）。

## 6. 状态

- 验收结论已通知 pp（Bark）。
- 代码仍冻结；下一张任务单（间距 + 代码卡片常量）待 pp 点头后写。
