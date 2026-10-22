# Code 页视觉证据清单（对照 Claude iOS 1.261005.20）

> 目的：把 Code 页第一批视觉要素的「官方值 / 证据等级 / 现有主题是否已有」一次列清，供 `CodePageTheme.swift` 补值和真机复核使用。
> 范围：只覆盖 Code 会话时间线内的视觉要素（折叠行、DiffIndicator、chevron、运行态、Working mark、行距、代码卡、todos/diff/详情页标题）。不含 Chat 页、整页 shell、composer、列表页。
> 证据标记：`[E]` = CANONICAL / `DATA/tokens.json` 有据（指令、类型元数据、文件字节）；`[I]` = 参考图 / 视频取色量距（非官方二进制证据）；`[U]` = 无据，不得当事实用。
> 目标主题文件：`/home/ubuntu/aa-ring-work/ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodePageTheme.swift`

---

## 0. 读过的来源与取数方法

### 0.1 文档与 token

- `/home/ubuntu/aa-test/claude-ios-re/CANONICAL/04-tool-calls.md` §2、§4、§5.2、§6
- `/home/ubuntu/aa-test/claude-ios-re/CANONICAL/05-layout-scroll.md` §3
- `/home/ubuntu/aa-test/claude-ios-re/CANONICAL/06-visuals-assets.md` §1、§2、§3、§4
- `/home/ubuntu/aa-test/claude-ios-re/CANONICAL/11-motion-haptics.md` §0、§2、§3、§4
- `/home/ubuntu/aa-test/claude-ios-re/CANONICAL/20-working-mark.md` §1–§6
- `/home/ubuntu/aa-test/claude-ios-re/DATA/tokens.json`（全部 token）
- `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/video-mining-r3.md` §10（60 fps 抽帧结论）
- `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/manifest.json`（18 条入库参考、Tier 与版本分档）
- 现有主题：`/home/ubuntu/aa-ring-work/ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodePageTheme.swift`

### 0.2 参考图 / 视频帧（本次实际读图）

| 编号 | 文件（绝对路径） | 内容 | 版本可信度 |
|---|---|---|---|
| R1 | `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round3/video/frames/OH1_key/t0300.jpg` | 亮色 Code 会话；两条完成态折叠行 `Initialized session >` / `Read a file, searched code >` | 官方 2026-10-13 视频，版本簇 unknown；非 exact build |
| R2 | `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round3/video/frames/OH1_key/t0331.jpg` | 亮色；`Edited validate-email.ts +1 −1 >`、`Done.` 正文、`Diff +9 −2` / `#128` 胶囊 | 同上 |
| R3 | `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round3/video/frames/OH1_key/t0327.jpg` | 亮色；同一条 `Edited … +1 −1 >` + `•• Computing…` + 排队 composer | 同上 |
| R4 | `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round3/video/frames/OH1_key/t0325.jpg` | 全屏 `Diff` sheet：17 pt 标题、13 pt 文件行、diff 行、行内评论 | 同上 |
| R5 | `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round3/video/frames/OH1_key/t0333.jpg` | 亮色；`Edited … +1 −1 >` 与两个胶囊的稳定帧（复核取色） | 同上 |
| R6 | `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round3/video/frames/OH1_key/t0322.jpg` | `Diff` sheet 从底部推入的中间态 | 同上 |
| R7 | `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round3/video/frames/OH1_60fps/t03-35-700_f00103.jpg` 与 `.../t03-36-000_f00121.jpg` | `••• Cogitating…` 运行态特写（60 fps 段，另一缩放） | 同上 |
| R8 | `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round2/device/code_session_dark_en_permission_crop_723x1568.png` | 暗色会话；运行中的工具行 `Reading rocket.rs`（橙色环 + 时钟 + chevron）+ 权限卡 | 2026-09 实机裁剪，older |
| R9 | `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round3/device/code_subagent_sheet_light_en_1320x2868.png` | 亮色 sheet；标题 `general-purpose` 的详情页头 | 实机，older |
| R10 | `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round2/device/code_session_light_402pt_modal_1206x2622.png` | 402 pt 全屏；`Used App Batch >` 行、`Request Full Control` sheet（整屏被模态 scrim 压暗） | 日期 exact（#99609），但不可做颜色 gate |
| R11 | `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/device/code_session_dark_1170x2532.png` | 旧版暗色会话；展开的 `Agent` 卡、橙色状态点、暗色 composer | 2026-03 older |
| R12 | `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/device/code_session_light_cleared_1320x2868.jpg` | 亮色空会话；页面底色、composer | 实机，older |
| R13 | `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/marketing/*.png`（9 张） | App Store 营销合成图；无 Code 工具行/代码卡可取 | Tier 3，营销合成，不作 gate |

`round3/candidates/`（298 张）、`round2/rejected/`（57 张）与 `round3/clones/` **没有逐张读**：按 `manifest.json` 的 `round2_mining`/`round3_mining`/`round3_exact_hunt` 结论核对（304 张下载、42 张手机形态、5 张入选），候选池里没有额外出现折叠行 / 代码卡 / todos 的可量距图。入库的列表页图（`round3/device/code_tab_empty_dark_en_1206x2622.png`、`code_tab_devices_dark_en_1179x2556.png`、`round3/video/frames/Ko7_key/t077.jpg`）也读过，只含列表/空态，不含本清单要素。营销图（R13）只确认 Code tab 存在，不进入本清单取数。

### 0.3 量距校准与颜色口径

- **R1–R6（OH1 5 fps 帧）**：1920×1080 视频帧，手机 UI 内容区 x≈405–1514，宽约 1110 px。用四个已知量交叉校准得到 **≈2.86 px/pt（±5%）**：
  - 正文 17 pt 的 `D` 帽高 34 px（17 pt × 0.70 ≈ 11.9 pt → 2.86）；
  - 正文两行基线间距 78 px（27.2 pt → 2.87）；
  - 折叠行 15 pt 的 `E` 帽高 30 px（15 pt × 0.70 ≈ 10.5 pt → 2.86）；
  - DiffIndicator 圆角 13 px（4.5 pt → 2.89）。
  - 对应设备逻辑宽度约 388 pt；下文所有由这些帧换算的 pt 值均带 ±5% 不确定度。
- **R7（OH1 60 fps 段）**：同一 mockup 的另一缩放，UI 宽约 935 px（≈2.3–2.4 px/pt）。只用于点数、相对位置与颜色，不用于绝对尺寸。
- **R8（暗色裁剪）**：723×1568，按 @3x 计（3 px/pt）；裁剪非全宽，横向位置不可用。
- **R9/R10**：1206/1320 px 宽实机截图，@3x（3 px/pt），几何可用；R10 有 scrim 压暗，颜色不可用。
- 颜色全部取自 **H.264 视频帧 / JPEG**，4:2:0 色度抽样会让小字饱和度偏移；表中颜色为「实测范围」，不是官方色值。真机复核前不要把 [I] 颜色写死成品牌色。

---

## 1. 视觉要素清单

> 「主题现状」一列：`有` = `CodePageTheme` 已有对应 token；`部分` = 有近似值但语义/维度不全；`无` = 完全没有。
> 同一行若同时含 [E] 与 [I]/[U]，按「值」的主要来源定档，并在备注里写明另一档。

### 1.1 折叠行（CollapsedRow）

| # | 要素 | 值 | 档 | 出处 | 主题现状 |
|---:|---|---|---|---|---|
| V01 | 字体预设 / family | `Typography.monospaced`；预置字体家族 JetBrains Mono（用户设置里的等宽默认是 `sfMono`） | [E] | `04-tool-calls.md` §2.1；`06-visuals-assets.md` §1.3、§6.2 | 部分：有字号/行高/字重/TextStyle，无 family |
| V02 | 字号 | 15.0 pt（relative，`.footnote`） | [E] | `04-tool-calls.md` §2.1；`tokens.json` `toolRow.textSize` | 有 |
| V03 | 行高 | 24.0 pt（unscaled） | [E] | `04-tool-calls.md` §2.1；`06-visuals-assets.md` §1.3 | 有 |
| V04 | 字重 | 400 | [E] | `04-tool-calls.md` §2.1 | 有 |
| V05 | 折行/截断 | 单行；`truncationMode` 字段存在，具体模式 **UNKNOWN** | [E]（字段）/ [U]（模式） | `04-tool-calls.md` §4.1 | 无 |
| V06 | 按钮 padding | 6.0 pt | [E] | `04-tool-calls.md` §6.2 | 有 |
| V07 | 摘要动词色（light） | ≈ `#666664`（实测核心 #4C4C4A–#777775，JPEG 抗锯齿） | [I] | R1 `t0300.jpg` 的 `Initialized session` / `Read a file, searched code`；R2 `t0331.jpg` 的 `Edited` | 无 |
| V08 | 摘要参数/文件名色（light） | 正文色 `#131313`（视频中呈现为近黑 `#000000`） | [E] 色值 / [I] 绑定 | `06-visuals-assets.md` §2.2（text `0.075,0.075,0.075`）；R2、R3 | 无 |
| V09 | 摘要文字色（dark） | ≈ `#949492`（secondary 灰）；文件名按正文 `#F9F9F7` | [I] 灰 / [E] 正文色 | R8 暗色裁剪；`06-visuals-assets.md` §2.2 | 无 |
| V10 | 完成态 leading 图标尺寸 | `IconFrame` + Anthropicon `.large(2)`，`isBold=false`、`isFramed=false`；1x 名义 3–23 pt；**渲染尺寸 [U]** | [E] 结构 / [U] 尺寸 | `04-tool-calls.md` §4.1、§7.2；`06-visuals-assets.md` §4.2 | 无 |
| V11 | 完成态 leading 图标的参考观察 | 2026-10-13 视频里三条完成态折叠行**都没有可见 leading 图标**：文字左缘 = 16 pt 行边距（x≈456 @2.86） | [I] | R1 `t0300.jpg`（两行）、R2 `t0331.jpg`（`Edited` 行） | 无（与 V10 的 CANONICAL body 结构冲突，见 §5） |
| V12 | 运行态 leading 指示 | 橙色环 ≈9.7×9.3 pt（29×28 px @3x），环外径约 10 pt，暖橙色 ≈`#EFAB57`（外晕；更旧暗色图的同位置圆点为 `#D97757`） | [I] | R8 暗色裁剪；R11 `code_session_dark_1170x2532.png` | 无 |
| V13 | 运行态行内附加元素 | 标签后有时钟 glyph（≈7.7 pt）与 chevron | [I] | R8 | 无 |
| V14 | 行 pitch（视频实测） | 两条完成态折叠行基线间距 ≈126 px = **44 pt**，与「24 行高 + 2×6 padding + 2×4 segment padding」一致 | [I] | R1 `t0300.jpg` | 无（视图计算） |
| V15 | 行内元素间距 | label→badge ≈9.1 pt；badge→chevron ≈10.5 pt（预设值最可能是 8 pt） | [I] | R2 `t0331.jpg` | 无 |

### 1.2 DiffIndicator（`+N / −N` 胶囊）

| # | 要素 | 值 | 档 | 出处 | 主题现状 |
|---:|---|---|---|---|---|
| V16 | 字号 | ≈11.5 pt（`+1` 数字墨高 24 px = 8.4 pt） | [I] | R2 `t0331.jpg` | 有（11 pt，[I]） |
| V17 | 水平内边距 | ≈6.6 pt 左 / 5.9 pt 右 | [I] | R2 `t0331.jpg`（绿半：fill x1031–1101，glyph x1050–1084） | 有（8 pt，[I]） |
| V18 | 垂直内边距 | ≈4.2 pt 上 / 4.5 pt 下 | [I] | R2 `t0331.jpg`（fill y188–236，glyph y200–223） | 有（6.5 pt，[I]） |
| V19 | 单半宽 / 总宽 / 高 | 绿半 24.8 pt、粉半 24.5 pt；合计 ≈50.0 pt；高 17.1 pt（71+2+70 × 49 px @2.86） | [I] | R2 `t0331.jpg`；R5 `t0333.jpg` 复核一致 | 无（主题没有宽/高 token；注释里的 28×20.7 是 [I] 估算，见 §3） |
| V20 | 圆角 | 4.5 pt，`ScaledMetric`（随 Dynamic Type） | [E] | `04-tool-calls.md` §6.2；`tokens.json` `diffIndicator.cornerRadius` | 有 |
| V21 | 底色（light） | 绿 `#CEECD2`（206,236,210）；粉 `#EBCAD5`（235,202,213） | [I] | R2 / R5（两帧一致） | 有近似（`#D1E6D3` / `#E9CED5`） |
| V22 | 字色（light） | 绿 ≈`#299640`（10th pct 41,150,64；暗核 `#228C30`）；粉 ≈`#870032`（135,0,50；暗核 `#66001E`） | [I] | R2 / R5（两帧一致） | 有近似（`#487F4E` / `#882941`，偏差见 §3） |
| V23 | 底色 / 字色（dark） | **无证据** | [U] | 所有入库暗色图都没有 `+N/−N` 徽章 | 主题把 light 值复制到 dark（需复核，见 §3） |
| V24 | 结构 | 两瓣相邻：左绿 `+N`、右粉 `−N`，拼成一个胶囊；两瓣各自 4.5 pt 圆角 | [I] | R2、R5 | 无（只有颜色 token，形状在视图层） |
| V25 | 显示开关 | `SessionMessageStyle.showsDiffStat` 默认 **true** | [E] | `04-tool-calls.md` §6.1 | 无 |
| V26 | 详情行用法 | `CollapsedToolTimelineRow` 里是 `DiffIndicator.fixedSize` | [E] | `04-tool-calls.md` §4.2 | 无 |

### 1.3 Chevron（行尾 `>`）

| # | 要素 | 值 | 档 | 出处 | 主题现状 |
|---:|---|---|---|---|---|
| V27 | 尺寸（light） | 墨迹 21×40 px ≈ **7.3×14.0 pt**；笔画约 2.4 pt | [I] | R2 `t0331.jpg`（chevron bbox x1203–1223, y192–231）；R1 同形 | 无 |
| V28 | 尺寸（dark） | 14×27 px @3x ≈ 4.7×9.0 pt | [I] | R8 暗色裁剪（older build，与 V27 冲突，见 §5） | 无 |
| V29 | 颜色（light） | 核心 ≈`#4F4F4D`（79,79,77），中位 ≈`#626260` | [I] | R2 `t0331.jpg` | 无 |
| V30 | 颜色（dark） | ≈`#8B8B88`–`#979794`（与暗色行文字同族） | [I] | R8 | 无 |
| V31 | 位置 | 紧跟在 label/参数之后（非贴右缘）；见 V15 的 10.5 pt 间距 | [I] | R1、R2 | 无 |

### 1.4 Shimmer / 运行态 / 流式外观

| # | 要素 | 值 | 档 | 出处 | 主题现状 |
|---:|---|---|---|---|---|
| V32 | 折叠行 body 含 `ShimmerView` | 存在（`CollapsedRowButton(... ShimmerView ...)`） | [E] | `04-tool-calls.md` §4.1 | 无 |
| V33 | Shimmer 资产 | `shimmer-1..15`（15 帧） | [E] | `06-visuals-assets.md` §4.3 | 无 |
| V34 | Shimmer 帧率 / 帧尺寸 / 颜色 / 透明度 | **无证据** | [U] | 静态报告未给参数 | 无 |
| V35 | 运行中的折叠行外观（暗色实机） | 橙色环 + 灰色 label + 时钟 + chevron；单帧内看不到 shimmer 波 | [I] | R8 | 无 |
| V36 | Code 流式追加外观 | 4–8 个英文词/块，块间隔 50–100 ms，新块 30–50 ms 淡入；**不是逐字揭示** | [I] | `video-mining-r3.md` §10.3（OH1 60 fps 段） | 无 |
| V37 | Code 无逐字揭示 | `TextPacing.none`，不建 `RevealDriver` | [E] | `11-motion-haptics.md` §4 | N/A（渲染路径） |

### 1.5 Working mark（`••• Computing…`）

| # | 要素 | 值 | 档 | 出处 | 主题现状 |
|---:|---|---|---|---|---|
| V38 | 尺寸 | 固定 **20×20 pt** | [E] | `20-working-mark.md` §5 | 有 |
| V39 | 帧率 | **30 fps** | [E] | `20-working-mark.md` §1 | 有 |
| V40 | 三段帧数 / 时长（think） | in 16 帧 = 0.53 s；loop 110 帧 = 3.67 s；out 15 帧 = 0.50 s | [E] | `20-working-mark.md` §1 | 有 |
| V41 | 弹簧 | `Spring(duration: 0.5, bounce: 0)` | [E] | `20-working-mark.md` §2 | 有 |
| V42 | 退出时长 / 缩放 | 0.4 s；`transform.scale` → 0.01 | [E] | `20-working-mark.md` §6 | 有 |
| V43 | 退出透明度 | keyframe values `[s8, s8, 0]`（报告标注为 INFERENCE） | [I] | `20-working-mark.md` §6 | 有（0，[I]） |
| V44 | 颜色（点 + 文字） | 暖棕 ≈`#B4675A`；暗核 `#A66150`–`#BB6D5E`；亮芯最高饱和 ≈`#D06751`（更旧暗色图的状态点为 `#D97757`） | [I] | R3 `t0327.jpg`（`Computing…`）；R7 60 fps（点）；R11 | 有（`#9D6E5C` 文字 / `#BB7A61` 点，[I]） |
| V45 | 三点几何 | 3 个点，直径约 2.5–3.8 pt（60 fps 段 6–9 px @2.4），斜向排列在 20×20 盒内；点组横向约占 16.6 pt | [I] | R7 `t03-36-000_f00121.jpg` | 无 |
| V46 | mark→文字间距 | ≈10–12 pt（60 fps 段 29 px @2.4；5 fps 段 47 px @2.86 偏大，取前者） | [I] | R7；R3 | 无 |
| V47 | 状态行文字字号 | ≈15 pt（墨高 35 px @2.4 ≈14.6 pt） | [I] | R7 `t03-35-700_f00103.jpg` | 有（15，[I]） |
| V48 | 状态行左内缩 | ≈20–22 pt（比折叠行的 16 pt 多约 4–6 pt） | [I] | R3（62 px @2.86）、R7（49 px @2.4） | 无 |
| V49 | 动词轮换 | `connecting` 20 动词表，1 s 轮换 | [E] | `20-working-mark.md` §4 | 有 |
| V50 | Reduce Motion | `isStill` 时只播单帧 | [E] | `20-working-mark.md` §5 | 无（视图分支） |

### 1.6 行边距 / 间距 / 块间距

| # | 要素 | 值 | 档 | 出处 | 主题现状 |
|---:|---|---|---|---|---|
| V51 | `rowMargins` | `(top 5, leading 16, bottom 5, trailing 16)` | [E] | `05-layout-scroll.md` §3.1；`tokens.json` | 有 |
| V52 | `interMessageSpacing` | 10.0 pt | [E] | `05-layout-scroll.md` §3.3 | 有 |
| V53 | `segmentVerticalPadding` | 4.0 pt | [E] | `05-layout-scroll.md` §3.3 | 有 |
| V54 | `briefCardSpacing` | 8.0 pt | [E] | `05-layout-scroll.md` §3.3 | 无 |
| V55 | Markdown 块间距 | 16.0 pt | [E] | `06-visuals-assets.md` §3.1 | 有 |
| V56 | `interBlockSpacing` | `nil`（默认） | [E] | `05-layout-scroll.md` §3.3 | 无 |
| V57 | `interBlockSpacing = nil` 时的 SwiftUI 默认值 | **blocked**，无官方值 | [U] | `05-layout-scroll.md` §3.3 | 无（需要 AA 自己给设计值） |
| V58 | `groupedMessageSpacing` | `nil`（默认） | [E] | `05-layout-scroll.md` §3.3 | 无 |
| V59 | 行底 padding | `interMessageSpacing − (groupedMessageSpacing ?? interMessageSpacing)`；默认 0 | [E] | `05-layout-scroll.md` §3.2 | 有（硬编码 0） |
| V60 | 视频实测的纵向节奏 | 折叠行（badge 底）→下一段正文顶 ≈27 pt（76 px @2.86）；行 pitch 44 pt（见 V14） | [I] | R1、R2 | 无（视图计算） |

### 1.7 代码卡（CodeBlock，assistant 正文里的代码块）

| # | 要素 | 值 | 档 | 出处 | 主题现状 |
|---:|---|---|---|---|---|
| V61 | header 高 | **44.0 pt**（`ScaledMetric<Double>`） | [E] | `06-visuals-assets.md` §3.3 | 无 |
| V62 | 标题字号 / 字体 | **13.0 / 20.8 / 400 / `.caption` / JetBrains Mono** | [E] | `06-visuals-assets.md` §1.3、§3.3；`tokens.json` `codeCard.title.typography` | 无 |
| V63 | 正文排版 | 15.0 / 24.0（monospaced 预置） | [E] | `06-visuals-assets.md` §1.6 | 无（值与 V02/V03 相同，但没有 codeCard 语义 token） |
| V64 | 背景（light / dark） | `#FFFFFF` / `#20201F` | [E] | `06-visuals-assets.md` §2.3；`tokens.json` | 无 |
| V65 | 边框 / divider 颜色 | light `rgba(0.118,0.118,0.114,0.3)`；dark `rgba(0.882,0.878,0.851,0.3)` | [E] | `06-visuals-assets.md` §2.3 | 无 |
| V66 | 圆角 | **24.0 pt，`.continuous`** | [E] | `06-visuals-assets.md` §3.2；`tokens.json` | 无 |
| V67 | 正文内边距 | **16.0 pt 四边**（`contentInsets`） | [E] | `06-visuals-assets.md` §3.3 | 无 |
| V68 | header padding | 16.0 pt（`EdgeSet` 方向 UNKNOWN；几何上最可能水平） | [E] 值 / [U] 方向 | `06-visuals-assets.md` §3.3 | 无 |
| V69 | divider | 1 物理像素；仅 `title != nil` 时出现 | [E] | `06-visuals-assets.md` §2.3、§3.3 | 无 |

### 1.8 Todos / Diff / 详情页标题

| # | 要素 | 值 | 档 | 出处 | 主题现状 |
|---:|---|---|---|---|---|
| V70 | Todos 行结构 | 圆角描边复选框 + 可选 Anthropicon 勾（ScaleEffect）+ 文本 | [E] | `04-tool-calls.md` §5.2 | 无 |
| V71 | Todos 两态颜色 | 代码只区分 `completed` 与其余；两色 RGB **UNKNOWN** | [U] | `04-tool-calls.md` §5.2 | 无 |
| V72 | Todos 尺寸 / 圆角 / 行距 / 字号 | 无证据（入库参考里没有 todo 行） | [U] | — | 无 |
| V73 | Diff 行色（light / dark） | add `(0,0.576,0)` / `(0.047,0.639,0.047)`；remove `(0.816,0.231,0.231)` / `(0.89,0.286,0.282)` | [E] | `04-tool-calls.md` §5.2 | 有 |
| V74 | Diff 行结构 | add/remove 2 pt 彩色条 + gutter（`maxLineNumber` 位数）+ 高亮文本 | [E] | `04-tool-calls.md` §5.2 | 无 |
| V75 | Diff 截断 / 分页 | 展开卡 10 行（transcript 不用）；全屏 `PagedDiffRows` 300 行/页 | [E] | `04-tool-calls.md` §5.2 | 无 |
| V76 | 详情页标题 | `Diff` sheet：17 pt semibold、居中；左上圆形关闭钮（直径约 35 pt）；标题栏高约 50 pt；下缘 hairline | [I] | R4 `t0325.jpg`；R9、R10 的 sheet 标题同字号 | 无 |
| V77 | Diff 文件行 | 13 pt mono（与代码卡标题同一预置）+ 13 pt `+N/−N` 统计 | [I] | R4 `t0325.jpg`（文件行墨高 28 px、`+5` 27 px） | 无 |
| V78 | Diff 代码正文 | ≈12 pt 字号 / ≈15 pt 行高（行距 42–45 px @2.86）；官方 token 未闭合 | [I] 量距 / [U] 官方值 | R4 `t0325.jpg` 代码行 1–4 | 无 |
| V79 | Diff 背景与强调色 | 页面/文件行底 `#F9F9F7`；代码区底 `#F2F2F2`；加行底 `#E0F1DE`；评论目标行 `#FBF8C5`；统计绿 `#10AC0D`、红 `#B4263E` | [I] | R4 `t0325.jpg` | 无 |
| V80 | 页面背景 | light `#F9F9F7`（249,249,247）；dark `#151515`（21,21,21） | [I] | R1–R5；R8、R11 | 无 |
| V81 | `CollapsedToolCallList.title` 的呈现方式 | push / sheet / fullScreenCover **未定** | [U] | `docs/perf-6b-c5-code-profile-task.md` §11 | 无 |
| V82 | 子代理详情 sheet 标题 | `general-purpose`：17 pt semibold、居中；左上关闭钮 | [I] | R9 `code_subagent_sheet_light_en_1320x2868.png` | 无 |

---

## 2. 当前 `CodePageTheme` 缺的值

按主题现有分组列出（同一个值若已在 V 表里标「有」，这里不再重复）：

### 2.1 折叠行
1. 摘要**动词色**（light / dark）——V07、V09。
2. 摘要**参数/文件名色**（light / dark）——V08、V09。
3. 折叠行 **leading 图标**：资产选择、渲染尺寸、`isBold=false` / `isFramed=false` 的落码——V10。
4. 运行态 **橙色环**：外径 ~10 pt、描边、颜色 light/dark——V12；以及 V13 的时钟 glyph。
5. 折叠行 **行 pitch / 行内间距**（label→badge→chevron）——V14、V15。
6. 折行/截断模式——V05。

### 2.2 DiffIndicator
7. **宽 / 高**（单瓣与总宽）——V19。
8. **dark 底色 / 字色**——V23（当前复用 light）。
9. **双瓣结构**的几何语义（两瓣相邻、共享外轮廓）——V24。
10. `showsDiffStat` 开关——V25。

### 2.3 Chevron
11. **尺寸 / 笔画 / 颜色（light+dark）**——V27–V30。
12. 位置规则（跟随 label，不贴右缘）——V31。

### 2.4 Shimmer / 运行态 / 流式
13. **Shimmer**：帧资产、帧率、帧尺寸、颜色、透明度——V33、V34。
14. 运行态折叠行与 shimmer 的组合规则——V35。
15. 流式块追加的淡入参数（4–8 词 / 50–100 ms / 30–50 ms）——V36（若视觉层需要）。

### 2.5 Working mark
16. **三点几何**：点径、点间距、斜向排布——V45。
17. **mark→文字间距**——V46。
18. **状态行左内缩**——V48。
19. **dark 色**（点与文字）——V44（当前复用 light）。
20. Reduce Motion 单帧分支——V50（视图层）。

### 2.6 行距
21. `briefCardSpacing` 8 pt——V54。
22. `interBlockSpacing` 的显式设计值（官方是 nil + blocked）——V56、V57。
23. `groupedMessageSpacing` 语义——V58。
24. 视频实测的纵向节奏（若要按官方观感对齐）——V60。

### 2.7 代码卡
25. **全部**：header 44、标题 13/20.8/400 caption mono、正文 15/24、背景 light/dark、边框/divider、圆角 24 continuous、正文 inset 16、header padding 16（方向待定）、1 物理像素 divider 与 `title != nil` 条件——V61–V69。

### 2.8 Todos / Diff / 详情页
26. **Todos 全部**：复选框尺寸/圆角/描边、勾图标、行距、文本字号、两态颜色——V70–V72。
27. **Diff 详情**：2 pt 色条、gutter 宽度、高亮行、10/300 行策略、文件行 13 pt、代码正文 ≈12/15、加行/高亮/统计色、页面背景——V73–V80。
28. **详情页标题**：17 pt semibold、居中、关闭钮、标题栏高度、hairline——V76；子代理 sheet 同款——V82。
29. `CollapsedToolCallList.title` 的呈现方式——V81。

---

## 3. 主题里 `[I]` 值需要真机复核

> 复核方法：同一台设备（默认 Dynamic Type、英文、light/dark）截 Code 会话，量距用 3x 原生图；颜色用 sRGB 取色。下表「本次实测」来自 R2/R5（light）与 R8（dark），带 §0.3 的 ±5% / JPEG 偏移。

| 主题里的值 | 主题现值 | 本次实测 / 判断 | 风险 |
|---|---|---|---|
| `diffIndicatorFontSize` | 11 pt [I] | ≈11.5 pt（`+1` 数字墨高 24 px @2.86） | 低；可保留 11 或改 11.5 |
| `diffIndicatorHorizontalPadding` | 8 pt [I] | ≈6.6 pt 左 / 5.9 pt 右 | 中；偏大 ~1.4–2 pt |
| `diffIndicatorVerticalPadding` | 6.5 pt [I] | ≈4.2 pt 上 / 4.5 pt 下 | 中高；偏大 ~2 pt |
| 注释中的徽章尺寸 | 28 × 20.7 pt [I] | 单瓣 ≈24.8 × 17.1 pt，总宽 ≈50.0 pt | 中高；宽/高各偏大 ~13–21%（可能来自另一张图的缩放假设） |
| `diffIndicatorAddText` | `#487F4E` [I] | ≈`#299640`（暗核 `#228C30`） | 中；色相接近、饱和度偏低 |
| `diffIndicatorRemoveText` | `#882941` [I] | ≈`#870032`（暗核 `#66001E`） | 中；色相接近、饱和度偏低 |
| `diffIndicatorAddFill` | `#D1E6D3` [I] | `#CEECD2`（206,236,210） | 低 |
| `diffIndicatorRemoveFill` | `#E9CED5` [I] | `#EBCAD5`（235,202,213） | 低 |
| `workingMarkTint` | `#BB7A61` [I] | 点/文字 ≈`#B4675A`；亮芯 ≈`#D06751` | 中；建议真机取色后定值 |
| `runningStatusColor` | `#9D6E5C` [I] | 文字 ≈`#A66150`–`#BB6D5E` | 中 |
| `runningStatusFontSize` | 15 pt [I] | ≈14.6–15 pt | 低 |
| `workingMarkExitOpacity` | 0 [I] | CANONICAL 明确标 INFERENCE | 低（行为正确即可） |
| 所有 `SchemeColor.dark` | 复用 light | **没有暗色参考**：DiffIndicator、working mark、运行状态、行文字/chevron 的 dark 值都未取 | 高；真机暗色必须逐项复核 |
| V07/V09 折叠行文字色 | （主题还没有） | light ≈`#666664`；dark ≈`#949492`（older capture；同一图里另一行更暗，存在版本差异） | 高；暗色尤其需要真机 |

**另有一个口径问题**：主题把 `diffIndicator*Text` 注释为「screenshot 2026-10-22」取样，但没有记录取样图/缩放假设。本次在同一批 OH1 帧上得到不同的宽/高/内边距，说明这批 [I] 值必须先统一「参考帧 + px/pt 比例」再收敛；在真机图到手前，建议保留现值不动，只在文档里标「待复核」，不要按视频数字再改一版。

---

## 4. `[U]` 未闭合项汇总

1. **DiffIndicator dark**：底色、字色、描边（无暗色参考图）。
2. **Shimmer 参数**：帧率、帧尺寸、颜色、透明度、与文字的叠加方式。
3. **折叠行完成态图标**：CANONICAL 说 body 有 `IconFrame`，但 2026-10-13 视频三条完成态行都没有可见图标；到底「完成态不画」还是「该版本没有」，需要真机确认。
4. **图标渲染尺寸**：`Anthropicon.Size.large(2)` 对应的 pt 尺寸（资产 1x 名义 3–23 pt，不能统一 24）。
5. **Todos 两态颜色**与**复选框尺寸/圆角/行距/字号**（代码只区分 completed，RGB UNKNOWN；无参考图）。
6. **Diff 代码正文字号/行高**：视频量到 ≈12/15，官方 token 未闭合；与代码卡的 15/24 不是一个值。
7. **`CollapsedToolCallList.title` 的呈现方式**（push/sheet/fullScreenCover）——任务单 §11 已标 [U]。
8. **`interBlockSpacing = nil` 的 SwiftUI 系统默认间距**（blocked，206 无 iOS SDK）。
9. **代码卡 header padding 的方向**（值 16 pt 已证，EdgeSet 方向 UNKNOWN）。
10. **Detail 页标题栏高度/关闭钮精确直径**：R4 量到约 50 pt / 35 pt，但视频缩放与卡片阴影让边界不精确，按 [I] 低置信处理。
11. **暗色行文字/chevron 的准确色值**：两张 older 暗色图的灰度不一致（`#949492` vs `#4D4D49`），不能判断是版本差异还是状态差异。

---

## 5. 冲突与注意事项

1. **CANONICAL body 结构 vs 视频观感（折叠行图标）**
   - `04-tool-calls.md` §4.1 的 body 是 `CollapsedRowButton(HStack(label, DiffIndicator?), IconFrame, ShimmerView, Text)`，即结构上有 `IconFrame`。
   - 但 R1/R2 的完成态行文字都从 16 pt 行边距开始（x≈456 @2.86），没有给图标留位；只有 R8 的运行态行有橙色环。
   - 结论：**不要把「完成态折叠行一定有一个 leading Anthropicon」当成已证事实**；先按 [U] 处理，真机确认。

2. **视频版本不是 exact build**
   - R1–R7 来自官方 2026-10-13 视频（比目标 build 晚 8 天，版本簇 unknown；`video-mining-r3.md` §1）；R8、R11、R12 是更旧的实机截图；R9 版本未标；R10 的日期与 exact build 吻合（#99609，2026-10-05）但整屏被模态 scrim 压暗。
   - 所以本文件的 [I] 值只能做「形态与量级」参考，不能做像素 gate；这与 `manifest.json` 的 `pixel_gate_usable=false` 一致。

3. **视频 mockup 的 pt 换算不是官方值**
   - 5 fps 帧的 2.86 px/pt 是由正文 17 pt / 27.2 行高 / DiffIndicator 4.5 圆角交叉校准出来的，设备逻辑宽度约 388 pt；不同帧的缩放并不完全一致（60 fps 段约 2.3–2.4 px/pt）。
   - 表里的 pt 值都带 ±5% 不确定度；`[I]` 不等于官方。

4. **JPEG 取色偏差**
   - 徽章字色（`#299640` / `#870032`）、Working mark（`#B4675A`）、暗色行灰（`#949492`）都来自 H.264 4:2:0 帧；小字饱和度会被压低或抖动，真实值以真机 sRGB 取色为准。

5. **旧暗色图的字号/chevron 偏小**
   - R8 的 `Reading rocket.rs` 行文字墨高约 8 pt、chevron 4.7×9 pt，明显小于 light 视频的 15 pt / 7.3×14 pt。R8 是 2026-09 的 older build，且可能是「运行中 live 行」而非完成态折叠行；**不要用 R8 定字号/尺寸**，只取颜色与运行态构成。

---

## 6. 参考图 / 帧索引（[I] 出处速查）

- 完成态折叠行（light）：`/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round3/video/frames/OH1_key/t0300.jpg`
- `Edited … +1 −1 >`（light）：`/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round3/video/frames/OH1_key/t0331.jpg`、`.../t0333.jpg`、`.../t0327.jpg`
- Working mark `Computing…` / `Cogitating…`（light）：`.../t0327.jpg`、`/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round3/video/frames/OH1_60fps/t03-35-700_f00103.jpg`、`.../t03-36-000_f00121.jpg`
- Diff sheet（light）：`.../t0325.jpg`（稳定帧）、`.../t0322.jpg`（推入过程）
- 暗色运行行（older）：`/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round2/device/code_session_dark_en_permission_crop_723x1568.png`
- 详情 sheet 标题（light）：`/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round3/device/code_subagent_sheet_light_en_1320x2868.png`、`/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round2/device/code_session_light_402pt_modal_1206x2622.png`
- 暗色页面底：`/home/ubuntu/aa-test/claude-ios-re/REFERENCES/device/code_session_dark_1170x2532.png`、R8
- 亮色页面底：`/home/ubuntu/aa-test/claude-ios-re/REFERENCES/device/code_session_light_cleared_1320x2868.jpg`、R1–R5

---

## 7. 一句话结论

- **可直接落码、无需复核**：[E] 的字体 15/24/400、按钮 padding 6、DiffIndicator 圆角 4.5、diff 行色、Working mark 20×20/30 fps/三段时长/0.5 弹簧/0.4 s 退出、行距 [E] token（`interBlockSpacing` 默认值除外）、代码卡几何与颜色（header padding 方向、divider alpha 分工除外）。
- **必须真机复核后再写死**：DiffIndicator 的宽/高/内边距/字色、折叠行动词灰与文件名黑、chevron 尺寸与颜色、Working mark 的暖棕色、所有 dark 值。
- **仍是 [U]、不得当事实用**：Shimmer 参数、完成态 leading 图标是否存在/多大、Todos 两态色与行度量、Diff 代码正文字号、`CollapsedToolCallList.title` 呈现、`interBlockSpacing` 的系统默认。
