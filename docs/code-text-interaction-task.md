# Code 页正文链接 + 选中复制（2026-10-27）

> 目标：Code 页助手正文里的 Markdown 链接可点、可跳转；正文长按可选中并复制。
> 基线：`feat/code-profile-beta` @ `c36b6fad`（build 592）。

## 1. 现状 / 根因

- Code 页正文由 `CodeMarkdownTextLeaf` → `CodeMarkdownTextStackView` → `AssistantMarkdownBlockTextView` 绘制。
- `AssistantMarkdownBlockTextView` 初始化时：
  - `isSelectable = false`
  - `isUserInteractionEnabled = false`
  - 没有 `UITextViewDelegate`
- 所以链接点击事件进不来（`isUserInteractionEnabled=false`），也没有系统选择/复制。

## 2. 官方证据

- `EVIDENCE/UPSTREAM/part-aa-markdown-ui.md` §Q6：
  - `MarkdownUITextView` 的 `textView:primaryActionForTextItem:` 对 `.link(URL)` 返回自建 `UIAction`，handler 走 `openURL`/`spanHandler`（E）。
  - 普通 `MarkdownTextView` 用 `tapGestureRecognizer` 处理链接；长按交给菜单（E）。
  - 代码块在复合选择里可作屏障；表格不参与字符级选择（E/I）。
- `CANONICAL/06-visuals-assets.md`：链接颜色 = 正文色，**不是蓝色**；链接 underline = 1。
- 官方完整选择是跨块 `SessionCompositeTextSelectionAdapter`；本批只做**单块系统选择/复制**，跨块复合选择保留为后续（U）。

## 3. 本批范围

- 只对 Code 页的 **`.text` 块**启用交互（不改 Chat；不改代码块内部选择）。
- 链接：
  - `http` / `https` / `mailto` / `tel` 走 `UIApplication.shared.open`；
  - 其他 scheme 忽略（避免 `file:`/自定义 scheme 误开）。
  - iOS 17+ 用 `primaryActionForTextItem`；旧系统保留 `shouldInteractWith`。
- 选择/复制：
  - `isSelectable = true` + `isUserInteractionEnabled = true` → 系统长按选择 + Copy 菜单；
  - 单块内可跨段落选择；跨块选择不在本批。
- 视觉：链接使用正文色 + 单下划线（`linkTextAttributes`），不引入系统蓝。

## 4. 验证

- `swiftc -parse` 改动文件。
- CI `test` / `build` / `code-profile`（高度不得因选择/链接改变；gate delta 仍 0/阈值内）。
- 真机：
  1. 点正文里的 https 链接 → Safari（或系统 openURL）打开；
  2. 长按正文 → 出现选择把手/菜单 → Copy → 粘贴内容正确；
  3. 选择/滚动不冲突，行高不变。

## 5. 文件

- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/TextKit/AssistantMarkdownTextLayout.swift`
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeMarkdownTextLeaf.swift`

## 6. 后续（不在本批）

- 跨块复合选择 + HTML/plain 剪贴板（官方 `CompositeTextSelection` / `CopyToClipboard`）。
- 文件路径链接路由到 AA 文件查看器；App 内浏览器（Tailscale/WKWebView）。
- 表格/列表/引用内的链接与选择。

## 7. 构建

- build **594**（head `567125d7`，含本任务 + CI run 标题规则）：run `40499066444`，`test` ✅、`build` ✅、`code-profile` ✅（`failures: []`）。
- IPA：`AgentsAnywhere-feat-code-profile-beta-b594-567125d.ipa`（17,118,062 B）
  `https://github.com/chenyynx/Agents-Anywhere/releases/download/ipa-feat-code-profile-beta/AgentsAnywhere-feat-code-profile-beta-b594-567125d.ipa`
- 已下载核对 `CFBundleVersion = 594`。
- run 标题已验证：`iOS Build · 正文链接+选中复制`。

## 8. 595（链接点击兜底）

- 594 真机：链接有下划线但点击无反应；`UITextView` 自带的 link action 在 hosted list 里没有触发。
- 595：在 `AssistantMarkdownBlockTextView` 上额外加 `UITapGestureRecognizer`，按点击位置解析 `.link` 属性并打开；系统 delegate 路径保留，0.4 s 内同一 URL 去重，避免一次点击开两次。
- 范围仍是 per-block 选择；跨块选择未做。

## 9. 根因（596 之后定位）

- 594–596 全部无反应，不是触摸层：`AssistantMarkdownDocument` 的 run→NSAttributedString 转换只从 `run.link` 取了颜色/下划线，**没有把 `NSAttributedString.Key.link` 写进 attributes**（`AssistantMarkdownDocument.swift:1154` vs `:1178-1182`）。
- 所以屏幕上有下划线但没有可点击 link；UITextView 和自定义 tap 的 `attribute(.link)` 都返回 nil。
- 修复：构造 attributes 时补 `if let url = run.link { attributes[.link] = url }`。
- 门禁新增 `verifyLinkAttribute()`：解析 `[release](https://example.com/release)`，断言 `.link` == URL 且 underline == 1。

## 10. 597（根因修复）

- head `520c45cf`，run `40509037631`，标题 `iOS Build · 正文链接 .link 属性修复`；`test`/`build`/`code-profile` 全绿（`failures: []`），gate `links = {underline: 1, url: https://example.com/release}`。
- IPA：`AgentsAnywhere-feat-code-profile-beta-b597-520c45c.ipa`（17,122,471 B）。
- pp 2026-10-27 真机：「我已经下载了 现在可以了」= **链接点击验收通过**。
- 选中复制 pp 2026-10-27 验：「选中复制没问题」= **单块系统选择/Copy 验收通过**。

## 11. 2026-11-21 表格单元格选中 + 正文跨块选择（feat/text-selection）

> 本节取代 M3.4 文档中「表格单 surface、无逐格子视图、表格不参与字符级选择」的结论；代码以本节为准。

**需求（pp）**：表格里的文字要能选中复制；正文要能跨段落/列表项连续选择、一次复制（此前每块各自选择，拖到块尾就停）。

**表格**（`AssistantTableBlockView`）
- 结构：surface 只画表头填充、行线、外框；每个非空单元格一个 `AssistantMarkdownTextBlockView`（内含 `AssistantMarkdownBlockTextView` + chip overlay），frame 为 `textRect`。列宽/行高仍由 `AssistantMarkdownTextLayout.tableMetrics` 决定，视觉规格未改。
- 交互：`CodeMarkdownTextLeaf.enableBlockInteractions` 只给表格子树开单块选择；正文块不再各挂交互。
- 流式：`update(table:)` 在列宽/内边距不变时复用 cell 视图，只替换变化的单元格文字；高度返回走 `AssistantMarkdownTextLayout.height(.table)` 的 roundUp，与行高一致。
- 与官方差异：官方表格 surface 不参与字符级选择（`EVIDENCE/UPSTREAM/part-aa-markdown-ui.md` Q3）；表格可选是 pp 指定的产品决定。
- 链接：表格 cell 的 `.link` 仍在转换时剥掉（2026-11-18 的墨色决定）；格内链接不在本次范围。

**正文跨块**（`AssistantCompositeSelectionOverlay`）
- 在 `CodeMarkdownTextStackView` 上盖一层透明 overlay，实现 `UITextInput`，挂单个 `UITextInteraction(.nonEditable)`；所有正文文字视图（段落/标题/列表项/引用）按文档顺序成为参与者。
- 虚拟文本由 `CompositeSelectionModel` 维护：块间分隔符按类型取 `\n\n`（段落）或 `\n`（列表/引用），范围 ↔（块, 块内 offset）纯函数映射；选区矩形、caret、链接命中都映射回各块；Copy 跨块拼 HTML + 纯文本。
- 代码块、表格不参与：代码保留复制按钮，表格保留单元格选择；拖动跨过它们时按最近文字块吸附，不复制其内容。
- 流式：参与者列表在记录变化时刷新；选中范围内块的长度或 digest 变化才清选区，尾部增长时保留并按块内 offset 重映射。
- 单测：`ios/Tests/ClientCoreTests/CompositeSelectionModelTests.swift` 覆盖空块、默认/长分隔符、跨块、越界、clamp、单块。
- 门禁：`code-profile` 用 `codeTable` fixture 在 key window 渲染生产同款 `CodeMessageRowView`，断言表格每个 cell 有可交互文字视图、正文是 overlay 参与者且已装系统交互、overlay 确实覆盖 stack；另有 `tableReuse` 用例对同一个 `CodeMarkdownTextStackView` 连续安装两份表格文案，断言 cell 视图实例复用且仍可选中。M3 gate 保留表格 cell 结构断言（其驱动的是旧 `AssistantMarkdownCell`，不覆盖选择能力）。

**范围外（后续）**：跨单元格拖选；表格并入正文连续选区；选择时拖到屏幕边缘自动滚动；跨消息选择；表格 cell 内链接。
**验证状态**：单元/门禁以 CI 结果为准；真机验收（表格长按选/复制、跨段落与列表项拖选、流式期间选择、滚动与代码块复制按钮）待 pp 用出包确认。

### 11.1 选择交互补齐（2026-11-21，pp 真机反馈）

- **自动滚动**：overlay 在窗口上装一个并行 pan（`cancelsTouchesInView = false`），只在触点落在选区把手附近时开始；手指进入时间线可视区上下 90pt 带时，用 `CADisplayLink` 滚动最近的祖先 `UIScrollView`，逐帧把拖动的另一端映射到边缘文字；离开边缘、松手、取消或选区清空即停。初始长按拖动也能覆盖（recognizer 在视图入窗时就装好）。
- **选区颜色**：新增 `CodePageTheme.selectionTintUIColor`（light `#363636`，dark 白）。按截图取样：页面 249，官方高亮 210，原实现 199；系统按 tint 20% 画高亮，`#363636` 得到 210。
- **菜单**：补 `selectAll`（全选）。官方菜单的朗读/分享、以及去掉翻译/搜索网页属于菜单裁剪，未做。
- **未验证**：把手命中阈值、自动滚动速度、与系统把手拖动共存、深色模式下的 tint，均需真机确认。
- **高亮形状**：官方选中的是一整块（截图竖向 1248→1964 连续、x 到文字列右缘），我们原来是逐行矩形。`selectionRects` 在相邻行/段之间插入桥接矩形（gap ≤ 40pt），首尾行保持原 x 以保住手柄位置；跨代码块/表格的大洞不桥接。
- **表格外框固定**：圆角/描边从滚动内容（surface）移到 `AssistantTableBlockView` 的固定 `borderView`，scrollView 设 cornerRadius 裁剪内容；横向滚动只移动表头/行线/文字，卡片边框不再随内容被裁掉。
