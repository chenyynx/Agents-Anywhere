# C5 / M3 任务单：静态助手正文的复杂块

> 前置：M2 完成（`docs/perf-6b-c5-m2-task-sheet.md`），分支 `feat/textkit2-assistant-body`（最新 `e82ffa2c`）。
> 默认开关仍为 off（`aa.timeline.collectionView`）；不合并、不发包、不碰 dev。
> **范围裁定**：M3 只做**静态**助手正文的复杂块；流式、选择、链接交互、Dynamic Type 中途变化、RTL 真机留 M4。若 pp 要把流式并入 M3，先改本节再开工。

## 0. 目标

把 M2 的「只接段落/标题」扩到产品实际会出现的全部静态块，并保持同一原则：

- 块由 TextKit 2 / UIKit 原生渲染，不用「补齐空格的纯文本」近似（M1 已证明 CD 的表格/代码块视觉差 66.67/27pt）。
- 测量与渲染仍共用一份 attributed/块模型；apply 前同步测高；不进入 estimate/pending/可见 cell 拟合。
- 任一未支持块 → 整行回退 hosting（不出现半套视觉）；支持一块就多接一类行。

## 1. 范围（按接入顺序）

1. **列表**：无序/有序、嵌套、item 间距、缩进、marker 对齐；沿用产品 `MarkdownBlockSnapshot` 的块间距 12pt。
2. **引用**：左侧竖条、内边距、嵌套引用；引用内段落/列表。
3. **代码块**：圆角卡片、语言头部、等宽字体、行高、横向滚动/换行策略；对齐产品 `ChatMarkdownCodeBlock` 的视觉。
4. **表格**：网格、表头、边框、列宽、单元格内 inline 样式；对齐 `ChatMarkdownTable`。
5. **附件**：图片（元数据尺寸占位 + 异步加载）、Git badge、math；同步测量只依赖元数据/固定样式，不等网络。
6. **行内**：M2 已有粗体/斜体/inline code/链接上色；M3 补删除线、嵌套 emphasis、链接的点击（M4 再开交互）。

**不做（M4）**：流式尾部重排、文本选择、链接跳转/长按菜单、无障碍细节、Dynamic Type 中途变化、RTL 真机、宽度变化的真机验证、非助手行。

## 2. 架构

```
AssistantMarkdownDocument
  blocks: [AssistantMarkdownBlock]
    .text(NSAttributedString)                 // M2 段落/标题；M3 引用/列表也用 text + 块级样式
    .code(AssistantCodeBlock)                 // 语言、代码、attributed 高亮
    .table(AssistantTableBlock)               // 行/列、单元格 attributed、列宽
    .attachment(AssistantAttachmentBlock)     // 图片/Git badge/math 的同步尺寸与 view 工厂

AssistantMarkdownCell
  vertical UIStackView (spacing 12)
    .text  → AssistantMarkdownBlockTextView
    .code  → AssistantCodeBlockView（卡片 + 头部 + 代码 text view）
    .table → AssistantTableBlockView（网格）
    .attachment → 现有产品视图的轻量 UIKit 包装（图片用元数据高度；Git badge 用固定样式）

AssistantMarkdownTextLayout
  measure(document,width,scale)
    .text  → TextKit 2 block height
    .code  → 头部 + 代码行数×行高 + 内边距（与 code view 同一公式）
    .table → 表头/行高 + 边框（与 table view 同一公式）
    .attachment → 元数据高度/固定高度
```

- 复杂块的测量公式放在**块自己的类型**里（`AssistantCodeBlock.measuredHeight(width:)` 等），cell 的 view 与测量共用，避免两份公式漂移。
- 列表/引用先走 text 路线：`NSTextList` + `NSParagraphStyle`（indent/headIndent/firstLineHeadIndent/tabStops），引用加左侧 2pt 竖条容器；若 TextKit 2 的 list marker 与产品差 >1pt，再升级为逐 item view。
- 代码块横向滚动：M3 先按产品行为（长行可横滚）实现，但**测量按换行后的高度**；若产品是横滚不换行，测量取固定行高×行数，cell 内放横向 `UIScrollView`。
- 表格列宽：沿用产品 `ChatMarkdownTable` 的列宽策略（等宽/内容自适应），测量与 view 共用列宽结果。
- 附件：图片高度 = 元数据 aspect + 最大宽；加载中/失败用固定占位高度；Git badge/math 用固定样式高度。

## 3. 解析与接入

- 复用 `AssistantMarkdownDocumentParser.parseBlocks`（Textual 管线 + `MarkdownBlockSnapshot`）。
- `AssistantMarkdownBlock` 的构建器按 `presentationIntent` 分派：
  - `.paragraph/.header` → `.text`（M2）
  - `.orderedList/.unorderedList/.listItem` → `.text`（带 list 样式）或 `.list`
  - `.blockQuote` → `.text`（带引用容器）
  - `.codeBlock` → `.code`
  - `.table/.tableCell` → `.table`
  - attachment run（图片/Git badge/math）→ `.attachment`
- 支持集合版本化：`AssistantMarkdownBlockKind` 的 supported 集合；任一 block 不在集合 → `assistantMarkdown` 返回 nil（回退 hosting）。
- 适配器仍只接 `.single` 静态助手消息（M2 条件不变）；流式/折叠/notice/附件行继续 hosting。
- 缓存键仍是 row revision + text + typography revision；复杂块的高度也走 `documentHeights`。

## 4. Gate（扩展 `aa-textkit-m2` → `aa-textkit-m3`）

独立 3 行 gate（无滚动），fixture 覆盖：标题、段落、粗体/斜体/删除线、inline code、链接、无序/有序列表（嵌套）、引用、代码块（带语言）、表格、图片附件、Git badge、math。断言：

1. `firstStored == documentMeasuredHeight`（0.5pt）。
2. `|cellContent − firstStored| ≤ 1pt`（文本块）；复杂块允许 ≤2pt（表格/代码/附件）。
3. 该行不进入 `pendingMeasurements`；`firstStored != estimateKind.height`。
4. 相邻 frame 不相交；cell frame 不裁剪 content。
5. 每个复杂块的测量值与产品 `ChatMarkdownView`（窗口内）对照：文本 ≤1pt、代码/表格 ≤2pt、附件 ≤2pt；超出必须记录差异来源（字体/内边距/列宽）。
6. 未支持块的解析契约：例如 M3 未接的构造仍应返回 nil 并回退 hosting。

## 5. 风险与处置

- **代码块/表格视觉移植**是主要工作量：先做测量与结构，再对齐颜色/圆角/边框/头部；每步用 gate 记录 Δ。
- **附件异步**：测量只依赖元数据；加载完成若高度变化，按图片 bubble 的现有策略处理（M4 真机验证）。
- **列表 marker**：TextKit 2 的 `NSTextList` 与产品 Textual 的 marker 缩进可能差 1–2pt；gate 记录，必要时改逐 item view。
- **解析成本**：complex 文档 parse 仍同步在主线程；gate 记录耗时，超预算在 M4 外置。
- **部分支持**：任何未支持 block 整行回退，避免“代码块是卡片、表格还是纯文本”的半套视觉。

## 6. 验证状态（2026-10-20）

### 已完成

- 提交：`aa7e8298` 列表/引用，`d2247afc` 空快照兜底，`43d1c4a5` 代码块，`7583dabc` 表格 + 构建修复。
- **全流程绿**：run `39364614409`（commit `7583dabc`）— `test` success、`timeline-autorun` success（C3 与 M3 同时绿）。
- M3 gate（iPhone Air / iOS 26.5）：
  - `stored 596 == measured 596`
  - `cellContent 596 == cellFrame 596`
  - `pending false`，`estimate 200` 未写入，`overlaps 0`，cell in window
  - 块统计：text 12 / list 4 / quote 1 / code 1 / table 1；top-level 8
  - 解析契约：plain/unordered/ordered/quote/code/table 接受；image 拒绝并回退 hosting
- 前两轮的真实问题：单测与 C3 既有 flake（重跑）；代码块无界测量容器的 `greatestFiniteMagnitude` 歧义（`7583dabc` 修复）。

### 实施决定

- 列表/引用走**逐 item / 递归容器视图**，没有用 `NSTextList`：产品的 marker 是 5pt `circle.fill` + decimal label，`NSTextList` 无法给出同样的 marker 栏宽；逐 item 也自然表达嵌套。
- 代码块**未移植语法高亮**：Textual 的 Prism tokenizer 是包内 internal API；M3 先用产品卡片底色 + 等宽单色，高亮留后续。高度/卡片结构与产品对齐。
- 表格列宽/行高在解析时按整点预计算，view 与测量共用；表格横向滚动，不随列宽重排。
- 内联 code 改为从块自身字号缩放（与 Textual `.fontScale` 一致），影响标题与表格单元格。

### 未覆盖 / 未验证

- 真机；流式；选择、链接点击/长按；Dynamic Type 中途变化；RTL 真机；产品视觉逐项对照（gate 只断言内部一致性）。
- 附件（图片 / Git badge / math）**尚未接入**：图片占位尺寸可同步确定，但 Git badge / math 依赖 Textual 内部 `TextEnvironmentValues` 与行内附件渲染。建议整体留 M4；若 pp 要求，可先做独立图片块。

## 7. 交付

- 代码 + gate 输出 + 本任务单的验证状态。
- 不合并、不发包、不碰 dev。
- 先做顺序：列表/引用 → 代码块 → 表格 → 附件 → gate 总装；每步可独立回退 hosting。
