# 任务单：聊天链接内置浏览器（SFSafariViewController）

- 日期：2026-10-23
- 级别：M（单端 iOS：1 个新视图 + 1 个路由函数 + 1 处钩子 + 单测）
- 分支：`feat/ios-in-app-browser`（基于 `origin/dev` `9ad2abe1`；不合 dev，出包走分支）
- 来源：pp 2026-10-23 定「先做聊天链接打开的浏览器，仅链接跳转」

---

## 1. 目标

聊天时间线里的 http/https 链接，在 App 内用 `SFSafariViewController` 打开；`mailto:` 等仍交给系统。

产品行为：

- 点聊天正文/工具卡/图片卡里的 http(s) 链接 → App 内全高 sheet 弹出 Safari 视图
- Safari 视图自带地址栏、分享、阅读器、Cookie/登录态（与 Safari 共享）、Done 关闭
- 文件引用（`aa-workspace-file://`）维持现状：走内部文件预览，不经过浏览器
- 非 http(s)/mailto 的 scheme（`javascript:`、`ftp:` 等）继续丢弃

## 2. 非目标

- 独立浏览器入口、地址栏输入、多标签、历史记录
- WKWebView 自绘浏览器（首版用系统 SFSafariViewController）
- 设置页/配对页等聊天之外链接的行为变更（保持系统 Safari）
- 时间线远程浏览器（另一条线，已押后）

---

## 3. 改动清单

### 3.1 新增路由（ClientCore，可单测）

新建 `/home/ubuntu/repos/AA-wt-in-app-browser/ios/Agents Anywhere/Agents Anywhere/Models/Chat/ChatLinkRouter.swift`

```swift
enum ChatLinkRoute: Equatable {
    case filePreview(SessionFileReference)
    case inAppBrowser(URL)
    case system(URL)
    case discarded
}

enum ChatLinkRouter {
    static func route(_ url: URL) -> ChatLinkRoute
}
```

规则顺序（必须与现状一致，文件引用优先）：

1. `SessionFileReference.reference(from:)` 命中 → `.filePreview`
2. scheme 为 `http`/`https`（大小写不敏感）→ `.inAppBrowser`
3. scheme 为 `mailto` → `.system`
4. 其余 → `.discarded`

理由：现有 `SessionChatView` 的内联逻辑（`Views/Chat/SessionChatView.swift:283-289`）只有把它抽出来才能写单测；`SessionFileReference` 在 ClientCore 内，可直接引用。

### 3.2 SessionChatView

`/home/ubuntu/repos/AA-wt-in-app-browser/ios/Agents Anywhere/Agents Anywhere/Views/Chat/SessionChatView.swift`

- `SessionSheet`（`:21-43`）增加 `case browser(URL)`，`id` 用 `"browser:\(url.absoluteString)"`
- `sheetContent(for:)`（`:96-119`）增加 `case .browser(let url): InAppBrowserSheet(url: url)`；switch 保持在独立方法内（该文件注释明确：内联会超类型检查预算，`:92-94`）
- `OpenURLAction`（`:283-289`）改为调用 `ChatLinkRouter.route(url)`：
  - `.filePreview` → 现有逻辑（`session.isValid` 时 `sheet = .preview`），返回 `.handled`
  - `.inAppBrowser` → `sheet = .browser(url)`，返回 `.handled`
  - `.system` → `.systemAction`
  - `.discarded` → `.discarded`
- 平台保护：`#if os(iOS) && !targetEnvironment(macCatalyst)` 时才走 `.browser`；MacCatalyst 回退 `.systemAction`（SFSafariViewController 在 Catalyst 的可用性未验证，CI 也不覆盖 Catalyst）

### 3.3 新视图

新建 `/home/ubuntu/repos/AA-wt-in-app-browser/ios/Agents Anywhere/Agents Anywhere/Views/Browser/InAppBrowserSheet.swift`

- `import SafariServices`
- `InAppBrowserSheet`: `NavigationStack` 可省略（SFSafariViewController 自带顶栏），直接 `SafariView(url:onDone:)` + `.ignoresSafeArea()` + `.appSheetPresentation(.expanded)`
- `SafariView: UIViewControllerRepresentable`：
  - `makeUIViewController` 创建 `SFSafariViewController`，设置 delegate
  - `Coordinator: SFSafariViewControllerDelegate` 的 `safariViewControllerDidFinish` → `dismiss()`（通过闭包）
  - `preferredControlTintColor` 用 App 主题色（可沿用现有 tint；不确定就留系统默认）
- 不设置 ephemeral（SFSafariViewController 没有该选项；它与 Safari 共享 Cookie，是预期行为）

### 3.4 单测

新建 `/home/ubuntu/repos/AA-wt-in-app-browser/ios/Tests/ClientCoreTests/ChatLinkRouterTests.swift`

覆盖：

- `aa-workspace-file://preview?path=/tmp/a.md` → `.filePreview`
- `https://example.com`、`HTTP://Example.com` → `.inAppBrowser`
- `mailto:a@b.com` → `.system`
- `ftp://example.com`、`javascript:alert(1)`、无 scheme 的普通文本（经 `URL(string:)` 能构造时）→ `.discarded`
- 带 fragment 的 http URL 保留 fragment
- 回归：文件引用优先于 http（例如 `aa-workspace-file` 不会被当成 http）

---

## 4. 状态与边界

- 加载/错误由 SFSafariViewController 自行处理；App 不额外加状态
- 深色模式/动态字号由系统视图处理
- 无新增文案，除非空状态；不需要本地化键
- 已有 sheet 打开时点链接：`sheet` 是单一状态，新值会替换旧 sheet（SwiftUI 会先 dismiss 再 present）；可接受，不做排队
- 离线：SFSafariViewController 显示系统错误页；App 不做额外兜底
- 安全：只放行 http/https；不注入 JS，不读网页内容

## 5. 验证

### 5.1 自动化

- `swift test --package-path ios`（ClientCoreTests 新增用例）
- CI `ios-build.yml` 全绿（test + build）

### 5.2 真机

1. 聊天里点 Markdown 链接 → App 内弹出 Safari 视图（不是跳出 App）
2. 工具卡/图片卡里的链接同样走内置
3. 文件引用仍打开内部文件预览
4. `mailto:` 走系统邮件
5. Done 关闭后回到聊天原位置
6. 设置页「官网」链接仍走系统 Safari（本次不改变）
7. 深色模式、横竖屏表现正常

### 5.3 回归

- 现有 sheet（文件预览、子代理面板、通知、详情、图片查看器）行为不变
- 聊天时间线行布局无位移（只加了路由与一个新 sheet case）

---

## 6. 风险

| 风险 | 处置 |
|---|---|
| SFSafariViewController 在 sheet 内表现（顶栏/安全区） | 真机验证；必要时改 `fullScreenCover` |
| MacCatalyst 编译可用性 | `#if` 隔离 + Catalyst 回退 `.systemAction`；CI 不覆盖 Catalyst，构建验证以 iOS 为准 |
| 现有 openURL 行为回归（文件引用/mailto） | 路由抽成纯函数 + 单测锁死 |
| 多 sheet 状态互相覆盖 | 单 `sheet` 状态，接受替换语义；真机验证无闪退 |

**工期**：0.5 天（实现 + 单测 + CI + 真机验收）。
