# C5：助手正文 TextKit 2 / UIKit 重写（严格对齐官方）

> 决策：2026-10-20，pp 定「走 2，严格对齐官方，别打补丁了」。
> 状态：计划已立，尚未开工。当前 `perf/session-open-and-render` 的 estimate + 可见 cell 拟合路线**冻结**，不再作为验收方向，也不再发包。

---

## 0. 一句话

把**助手正文**的 Markdown 渲染与高度测量迁到官方同一套 TextKit 2 / UIKit 引擎；其他行按官方范围保留 `UIHostingConfiguration`，但必须**同步可测**。不再用「先估算、再靠可见 cell 拟合修正」的补丁作为助手正文的主测量。

---

## 1. 根因（为什么必须换引擎）

- AA 的助手正文由 `ChatMarkdownView` 渲染，`StructuredText` 的 Markdown 解析在 `.task` 里异步执行（`ios/Agents Anywhere/Agents Anywhere/Views/Chat/Markdown/ChatMarkdownView.swift:18`、`:34-60`）。
- 离屏 `UIHostingController` 不进入 window，`.task` 不运行；CI 实测一个 1471pt 的长 Markdown 组在离屏只量到 **2.0pt**（run `39271249709`）。
- 于是只能估算 + 可见 cell 拟合；这会在第一帧把内容压进小高度，产生行内重叠/空白，并依赖大量补偿（stale key、width purge、settle 重试）。
- 官方不是这个结构：官方助手正文用 TextKit 2（`ClaudeMarkdownUI.MarkdownTextLayout` / `MarkdownTableLayout` / `MarkdownUITextView`），测量与渲染同一引擎；其他行才走 hosting。
- OpenMinis 也不是 TextKit 2：它用 `UICollectionView` 自测量 + `NSAttributedString.boundingRect()` 预计算 + TextKit 1 `UITextView` 自测（`MessageListLayout.swift:12/20-29/124`，`MessageListInfrastructure.swift:151/750`）。它的行是同步 UIKit，cell 一出现就能自测；AA 的 Textual 是异步，所以同一套「估算 + 自测量」在 AA 上第一帧就坏。**不要照抄 OpenMinis 的 TextKit 1 预计算。**

---

## 2. 官方范围（严格对齐，不扩大）

来自任务单 §13.2 / §6.8 的官方对照（原始报告在 `/home/ubuntu/wiring/docs/`，`part-z-textkit-height.md` 尚未落盘，不要引用不存在的章节）：

- **只有助手正文走 TextKit 2**。
- 用户消息、工具卡、files、分隔线、working、footer、历史加载器：`UIHostingConfiguration` 回退。
- 官方 TextKit 2 的类型证据（`types.json`，module.short_name + field）：
  - `ClaudeMarkdownUI.MarkdownTextLayout`: `textContentStorage` / `textLayoutManager` / `textContainer` / `textStorage`
  - `ClaudeMarkdownUI.MarkdownTableLayout`
  - `ClaudeMarkdownUI.MarkdownUITextView`: `customTextLayoutManager`
  - `ClaudeCoreUI.ScrollingChatTextMeasurements`: `cachedPlaceholderHeight` / `fittedWidth` / `measuringLayoutManager`
  - `ClaudeTranscriptUI.TranscriptCellHost`: `heightDidChange` / `reconfigure`
  - `ClaudeTranscriptUI.TranscriptListRowHeightEstimates`: `provide` / `cache`
- 关键点：官方是**同一引擎测量**，不是「用 A 引擎量、B 引擎画」。

### 2.1 现成 TextKit 2 实现调研（2026-10-20）

结论：有现成的，但没有「官方等价、直接替换聊天页」的成品；最接近的是 **CDMarkdownKit**，足以做 M1 spike 的底座。

- **CDMarkdownKit**（`chrisdhaan/CDMarkdownKit`，MIT，267★，活跃，iOS 13+ / Swift 6）
  - Markdown → `NSAttributedString`；支持标题、列表、引用、链接、代码块、GFM 表格、图片、自定义元素。
  - iOS 16+ 用 TextKit 2；`CDMarkdownTextView.sizeThatFits` 在**独立的 TextKit 2 stack** 里 `ensureLayout` + `usageBoundsForTextContainer` 量高（`Source/CDMarkdownTextView.swift:164-190`），与渲染同一套引擎。
  - `CDMarkdownParser.parse` 是 async；我们可以先 off-main 解析并缓存 attributed string，再同步 measure，正好符合「apply 前有高度」。
  - 风险：它是通用 Markdown 视图，不是 AA 的视觉层；主题、代码高亮、Git badge/文件链接、流式字形、附件交互需要移植；流式每 tick 重新 parse 的成本要测。
- **swift-markdown-engine**（`nodes-app/swift-markdown-engine`，Apache-2.0，1222★，活跃）
  - TextKit 2 + AST styling + 表格/代码/图片/LaTeX，但**只支持 macOS AppKit，是编辑器**；可作 AST→attributes 与 TextKit2 layout 的参考，不能直接用于 iOS 展示。
- **STTextView**（`krzyzanowskim/STTextView`，TextKit 2 text view，iOS 16+/macOS）
  - 文本视图底座，不是 Markdown 渲染器；许可证需单独核对（API 返回 NOASSERTION）。暂不作为首选。
- **MarkdownView** / **MarkdownDisplayView**：SwiftUI 渲染，不是 TextKit 2；MarkdownDisplayView 的流式思路可参考。

**M1 决策**：先用 CDMarkdownKit 做 spike；如果视觉 parity / 流式 / 性能过关，就 MIT vendor/fork 并移植主题；不过关再退回到自己搭 TextKit 2 stack（官方同形）。

---

## 3. 目标架构

### 3.1 助手正文

- 新增 `AssistantMarkdownTextLayout`（UIKit）：
  - `NSTextContentStorage` + `NSTextLayoutManager` + `NSTextContainer`
  - 用与渲染完全相同的 `NSAttributedString`（字体、行距、段落间距、inline code、标题、列表、引用、代码块）
  - 高度来自 `NSTextLayoutManager` 的 layout fragments（或同一 text view 的 `sizeThatFits(width:)`），在 **apply 前同步** 得到。
- 新增 `AssistantMarkdownCell`：
  - 直接承载 TextKit 2 文本 view（或官方式 `MarkdownUITextView` 的自定义布局管理器）
  - 不再用 SwiftUI `UIHostingConfiguration` 承载助手正文
  - 选择、链接、无障碍、Dynamic Type、RTL 在 UIKit 层实现
- 代码块 / 表格 / 附件：
  - 代码块：独立 UIKit 文本 view 或 TextKit 2 attachment；表格用官方同形的 `MarkdownTableLayout`/自定义表格 view。
  - 附件：尺寸来自元数据/加载回调；不在正文高度里用估算兜底。
- 流式：
  - 只重排改动段落之后的尾部（官方 §6.4 的方向）；测量同步完成后再 apply。
- 宽度 / 字号变化：
  - 宽度变化使该行整行失效并重新测量；不能等滚动或 cell 出现。

### 3.2 非助手行（严格按官方回退）

- 用户消息、工具卡、通知、files、分隔线、working、footer、历史加载器：继续 hosting。
- 但这些行的 Markdown/内容必须**同步可测**：
  - 预解析/预生成 blocks 在模型层完成并缓存；
  - hosting 的根视图从预解析 blocks 构建，不在 cell 的 `.task` 里解析；
  - apply 前用同一 hosting 树在离屏测高。
- 这是 C5「Markdown 外置解析」的同一件事；不做它，用户气泡仍会重现第一帧问题。

### 3.3 复用现有 C4 容器

- 复用 `TimelineCollectionController` / `TimelineListLayout` / diffable / 滚动 / 底部目标 / 历史前插。
- 新增测量路由：助手正文 → `TextKit2`；其他 hosting 行 → 预解析后的同步 hosting 测量。
- 删除/停用助手正文的 `estimate + 可见 cell 拟合` 主路径；保留 hosting 行在官方允许范围内的受控修正。
- 当前 `TimelineHeightEstimate` 只可作为**非正文 hosting 行**的等待期 fallback，不得再作为助手正文的测量来源。

---

## 4. 里程碑（新会话按顺序做，每步可验证）

### M1 · Spike（先证明，不接产品）

- 用 **CDMarkdownKit 的 `CDMarkdownTextView`** 作为底座（TextKit 2 + `sizeThatFits` 的 `usageBoundsForTextContainer`），在独立分支/临时 target 里渲染一条真实长助手 Markdown（含标题、列表、引用、代码块、表格、inline code）。
- 同时跑一个最小自建 TextKit 2 stack 作为对照，确认 CDMarkdownKit 的测量不是特例。
- 在同一宽度下，比较 TextKit 2 高度与当前 SwiftUI/Textual 渲染高度的差异；目标 ≤1pt（纯文本/段落）。
- 产出：高度对照表 + 失败项清单（表格/代码块/附件）。
- **不合并、不发包。**

### M2 · 静态助手正文接入

- `AssistantMarkdownTextLayout` + `AssistantMarkdownCell` 接入 collection timeline。
- 静态助手正文在 apply 前同步测量；删除该行的异步 hosting 测量。
- Gate：一条长助手的 `firstStored == rendered height`；无 estimate 写入；无行内重叠。

### M3 · 复杂块 / 流式 / 交互

- 代码块、表格、附件、链接、选择、无障碍、Dynamic Type、RTL。
- 流式尾部重排；每次 flush 只测尾部变更。
- Gate：streaming 高度单调、底部跟随、无每 tick 全量重排。

### M4 · 宽度 / 历史 / 真机

- 旋转/分屏宽度变化整行失效重测；历史前插锚点用新测量。
- 真机长会话：无重叠、无大片空白、顶部下拉/手点、顶底透明/soft。
- 通过后才允许打开实验开关给 pp 验收；默认仍 off。

---

## 5. 验收与不做的

**验收**
- 助手正文：测量与渲染同引擎；`firstStored` 等于渲染高度；无 estimate 作为测量。
- 非助手 hosting 行：预解析 + 同步测量；无 cell `.task` 解析。
- Gate 不再需要「可见 cell 拟合」作为助手正文的主路径。
- 真机截图 + 手势检查（XCUITest 合成拖拽；simctl 不能合成触摸，不能拿合成行 gate 代替）。

**不做**
- 不把 TextKit 2 扩到用户消息/工具卡等官方明确走 hosting 的行。
- 不用 TextKit 2 去量 Textual 渲染——两套引擎必然对不齐。
- 不再用「估算 + 可见 cell 拟合」作为助手正文主测量。
- 不在 gate 绿之前发包；不碰 dev；不碰生产。

---

## 6. 新会话启动

- 工作区：`/home/ubuntu/aa-ring-work`
- 建议分支：`feat/textkit2-assistant-body`，从 `perf/session-open-and-render` HEAD `bd74a013` 切出（复用 C4 容器；不合并）。
- 先读：
  - 本文件
  - `/home/ubuntu/aa-ring-work/docs/perf-6b-m1-task-sheet.md` §13.2、§14.4、§15、附录 C
  - `/home/ubuntu/wiring/docs/part-v-layout-height-cache.md`、`part-u-scroll-text-drawer.md`、`part-c.md`、`part-w-open-window-and-merge.md`
  - OpenMinis 只作对照：`/home/ubuntu/repos/openminis`（GPL-3.0，照着写不逐段复用）
- 第一件事：M1 spike，不接产品、不发包。
- 约束：重活只在 sbx；206 不跑重活；不碰 dev；不 force push；不提交密钥；不虚报/不编数字。
