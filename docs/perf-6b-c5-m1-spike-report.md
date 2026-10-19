# C5 / M1 spike 报告：助手正文 TextKit 2 测量

> 分支：`feat/textkit2-assistant-body`（**未合并、未发包**）
> 代码 commit：`51731f43`（报告本身在其后一次提交）
> CI run：`39333424930`（`textkit-spike` job success，`build`/`timeline-autorun` skipped）
> 环境：iPhone Air 模拟器，iOS 26.5，窗口 420×912pt @3x，正文列宽 388pt
> 排版：body 13pt，行距 7.4286pt（比例 8/14 × 13），字体行高 15.5137pt；设计段距 18.5714pt，产品块间距 12pt

## 0. 结论（先看）

1. **CDMarkdownKit 的测量就是 TextKit 2 的测量**：全部 fixture 里，`CDMarkdownTextView.sizeThatFits` 与最小自建 TextKit 2 stack 的最大差为 **0.89pt**，差异只来自 CD 对 `usageBoundsForTextContainer.maxY` 做 `ceil`。它可以作为 M2 的测量底座，不是特例。
2. **纯文本/段落达标**：修正测量容器后，TextKit 2 与当前产品 Textual 的实际渲染高度差为 **0.15–0.56pt**（单行 0.15，混合长段 0.35，纯中文 0.56），满足 M1 的 ≤1pt 目标。纯拉丁段 0.18pt。
3. **复杂块不达标，但属于视觉模型差异，不是测量误差**：表格 Δ66.67pt、代码块 Δ27pt、综合长回复 Δ141.67pt。CDMarkdownKit 把表格排成补齐空格的纯文本、代码块只有属性背景；产品是网格表格与代码卡片。这是 M2/M3 的移植清单。
4. **首轮 68pt 差异是测量容器的安全区，不是行高**：`UIHostingController.sizeThatFits` 把继承的顶部安全区（本设备 68pt）加进了高度；单行文本也出现 84 vs 15.51，零高度对照与离屏对照证实了这一点。修正后 host inset 全为 0，零高度对照为 0。

## 1. 高度对照表

### 1.1 引擎一致性：CDMarkdownKit vs 自建 TextKit 2

同一段分块 Markdown，两条路径各量一次（宽度 388pt）：

| fixture | CDMarkdownKit | 自建 TextKit 2 | 差 |
|---|---:|---:|---:|
| pureParagraph（中英混排） | 360 | 359.65 | 0.35 |
| pureLatin | 291 | 290.82 | 0.18 |
| pureCJK | 177 | 176.11 | 0.89 |
| singleLineLatin | 16 | 15.51 | 0.49 |
| singleLineCJK | 16 | 15.51 | 0.49 |
| paragraphs3 | 154 | 153.17 | 0.83 |
| richLong | 388 | 387.75 | 0.25 |
| tableOnly | 76 | 75.85 | 0.15 |
| codeOnly | 85 | 84.34 | 0.66 |

**判定**：两条路径是同一引擎。差值是 CD 的整点向上取整，不是布局差异。

### 1.2 产品 Textual vs TextKit 2

「产品」= 产品自己的 `ChatMarkdownView`，在窗口内等 `.task` 解析完成、高度稳定后读取（与线上渲染同一路径）。纯文本 fixture 用等价的纯 attributed string 量 TextKit 2；复杂块因为视觉模型不同，比较对象记为 CDMarkdownKit 的实际排版。

| fixture | 产品 Textual | TextKit 2（同排版） | 差 | 判定 |
|---|---:|---:|---:|---|
| singleLineLatin | 15.67 | 15.51 | **0.15** | PASS |
| singleLineCJK | 15.67 | 15.51 | **0.15** | PASS |
| pureLatin（约 19 行） | 291 | 290.82 | **0.18** | PASS |
| pureParagraph（约 16 行） | 360 | 359.65 | **0.35** | PASS |
| pureCJK（约 8 行） | 176.67 | 176.11 | **0.56** | PASS |
| paragraphs3 | 163 | 154（CD） | 9.14 | 段距映射项 |
| richLong | 529.67 | 388（CD） | 141.67 | 视觉移植项 |
| tableOnly | 142.67 | 76（CD） | 66.67 | 视觉移植项 |
| codeOnly | 112 | 85（CD） | 27.00 | 视觉移植项 |

`paragraphs3` 的 9.14pt 可以精确解释为 **2 × (12 − 7.4286)**：产品在 `MarkdownBlockSnapshot` 之间用 VStack 12pt，CD 的 `squashNewlines` 把空行折成单个换行，文字流里只有 7.4286pt 的行距。M2 需要把块间距写进 `NSParagraphStyle.paragraphSpacing`（或逐块测量求和），不是引擎问题。

## 2. 流式成本（CDMarkdownKit）

对 `richLong` 做 20 个递增前缀，每次 `parse` + `sizeThatFits`（Debug 构建 + 模拟器，主线程）：

| 指标 | median | p95 | max |
|---|---:|---:|---:|
| parse（`CDMarkdownParser`，@MainActor） | 2.55ms | 7.99ms | 17.50ms |
| measure（赋值 attributedText + sizeThatFits） | 1.35ms | 3.12ms | 3.72ms |

- 稳定态每 tick 约 **4ms** 主线程，60fps 预算内；Debug/模拟器是高估，Release/真机会更快。
- **冷启动另计**：首轮 run 的头两次 parse 分别为 221ms / 616ms（推断为解析器冷启动/正则惰性编译 + Debug，未单独验证）；流式第一帧前需要预热或把解析移出主线程。
- `CDMarkdownParser` 本身是 `@MainActor`，当前不能直接 off-main。

## 3. 失败项清单（M2/M3 输入）

1. **表格**：CD 用列宽补齐的纯文本，没有网格、边框、横向滚动；产品 `ChatMarkdownTable` 是自绘网格。Δ66.67pt（`tableOnly`）。按官方 `MarkdownTableLayout` 形状自建。
2. **代码块**：CD 只有属性背景，无圆角卡片、语言头部、语法高亮；产品 `ChatMarkdownCodeBlock` 是卡片。Δ27pt（`codeOnly`）。
3. **综合长回复 Δ141.67pt**：由标题字号（18/16/14）、列表缩进与 item 间距、引用边距、代码卡片、表格共同贡献；M2 需先建立块级样式/间距映射表。
4. **列表/标题/引用/行内 code**：CD 的字体派生与产品方案不同，未逐项量化（`richLong` 混合计入）。
5. **段距**：见 §1.2 的 9.14pt 解释；块模型层必须显式处理，不能直接喂原始 Markdown。
6. **解析线程**：`CDMarkdownParser` 是 `@MainActor`；流式每 tick 在主线程 parse。M2 若要求 off-main，需要用 nonisolated 解析器或自有 AST→attributed 转换。
7. **取整口径**：`CDMarkdownTextView.sizeThatFits` 对 `maxY` 做 `ceil`，最多 +1pt；M2 的 `firstStored == rendered` 要统一像素取整口径。
8. **未测**：图片/附件（网络 + 元数据）、选择、链接跳转、Dynamic Type、RTL、宽度变化、真机、真实 collection cell、Textual 流式路径。
9. **离屏对照**：`ChatMarkdownView` 不在窗口时测得 **0**（`.task` 不运行）；这正是 C5 要根除的第一帧问题，TextKit 2 的同步测量是解。

## 4. 方法（可复现）

- 启动参数 `aa-textkit-spike`（仅 DEBUG），根视图 `TextKitSpikeRootView`；CI 通过 `workflow_dispatch` 的 `textkit_spike=true` 拉起 `textkit-spike` job。
- 结果写入应用 `Documents/textkit-spike.json`，由 job 打印并作为 artifact 上传；不构建 IPA。
- 产品对照：把 `ChatMarkdownView` 放进窗口内的 `UIHostingController`，等解析完成且高度连续 4 次稳定（>8pt）后取 `sizeThatFits`。
- **测量口径**：探针视图放在窗口安全区内部（y = 顶部 inset），host inset 为 0；零高度对照 `Color.clear` 为 0，离屏裸 `Text` 与窗口内一致。
- 复现命令：对分支 `feat/textkit2-assistant-body` 派发 `.github/workflows/ios-build.yml`，输入 `textkit_spike: true`。

## 5. 边界与不做的

- 不合并、不发包、不碰 dev；M2 接线前不打开实验开关。
- 本报告只覆盖 M1 的两个问题：测量是否同引擎、纯文本是否对得齐；复杂块只给差异与迁移项，不是实现。
- CI 期间 `ModelSwitchRecoveryTests.stopStaysReachableWhenADeadProjectionSaysItCannotInterrupt` 两次把 `test` job 打红（任务单 §15.4 已记录的既有 flaky），重跑后通过，与本分支改动无关。
