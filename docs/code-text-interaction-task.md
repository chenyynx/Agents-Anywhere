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

- head `520c45cf`，run `40509037631`，标题 `iOS Build · 正文链接 .link 属性修复`。
- IPA：`AgentsAnywhere-feat-code-profile-beta-b597-520c45c.ipa`（17,122,471 B）。
- pp 2026-10-27 真机：「我已经下载了 现在可以了」= **链接点击验收通过**。
- 选中复制仍待 pp 继续验（596 的 isSelectable 已启用）。
