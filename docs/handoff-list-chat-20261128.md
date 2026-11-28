# 对话 tab 合并：会话 / 列表两模式 + 列表内 push（2026-11-28）

> 分支：`core`（原 `list` / `feat/list-chat`）= **core 线**（2026-11-28 pp 定，与 beta/next 平级、永不自动互合）；从 `next` 拉出，next 已合入 `feat/dashboard-library` @ `97749e69a`
> 范围：iOS only；不动 server / connector / web。

## 1. 目标 / 不做什么

**目标**
- 去掉 Devices tab；「对话」tab 同时承载会话和列表。
- **两种平级模式**：会话模式（会话/新建）与列表模式（设备页），各有抽屉。
- `查看全部` **切换到列表模式**（不是把列表 push 到会话上）：只关抽屉一个动画，列表直接就位。
- 列表里的每一行都是 **push**：点会话/新建都推在列表上，系统返回回列表。
- 设置新增「起始页面」：自动 / 会话 / 列表，默认自动。

**不做**
- 不做"列表 push 到会话上"（会叠抽屉关闭 + push 两段动画，pp 2026-11-28 否掉）。
- 不做 PagePicture 快照 / 隐藏页停 body。
- 不动时间线/揭示/行高。
- 不保留旧的双 tab 壳。

## 2. 导航模型

```
对话 tab
├─ 会话模式：会话页 / 新建页（抽屉）
└─ 列表模式：设备页（抽屉）
     ├─ 点会话 → push 会话页（系统返回回列表）
     └─ 新会话 → push 新建页 → 创建后替换成会话页
```

- 侧栏点会话/新建 → 切到会话模式（清空列表 push），只关抽屉。
- 侧栏「查看全部」→ 切到列表模式（列表根，无 push），只关抽屉。
- 列表页左上角是抽屉（列表是模式，不是 push 出来的详情）。
- 列表 push 出来的会话/新建页：左上角系统返回；新建页不带抽屉按钮。
- 列表里切换设备只改 `chatDevice`，不 push。

## 3. 状态模型

```swift
enum ShellTab { case chat, wiki, files, artifacts }

enum ChatTabRoot: Codable, Equatable, Sendable {
    case session(V2SessionID)
    case newSession(workspace: String?)
}

enum ChatTabMode: Codable, Equatable, Sendable {
    case conversation(ChatTabRoot)
    case list
}

enum ChatTabRoute: Codable, Equatable, Hashable, Sendable {
    case session(V2SessionID)      // push above the list
    case newSession(workspace: String?)
}

struct ShellPanesModel: Codable, Equatable, Sendable {
    var selectedTab: ShellTab = .chat
    var chatMode: ChatTabMode = .conversation(.newSession(workspace: nil))
    var listPath: [ChatTabRoute] = []
    var chatDevice: V2ConnectorID?
    var lastSessionID: V2SessionID?
}
```

- `visibleSessionId`：列表模式取 `listPath.last == .session`；会话模式取根 `.session`；列表根/新建根返回 nil。
- mutators：`openChatSession` / `startNewChat`（侧栏：会话模式）、`showList` / `openDevice`（列表模式根）、`pushChatSession` / `pushNewChat`（列表行 push）、`finishNewChat`（新建页换成会话页）。
- `lastSessionID` 在打开/推入会话时写入；删除/归档时清理。

## 4. 设置项：起始页面

- 位置：设置 → 通用 → 起始页面。
- 值：自动 / 会话 / 列表，默认自动；存储 `aa.shell.startPage`。
- 只在冷启动/恢复应用一次：
  - `auto`：恢复 `chatMode` + `listPath`
  - `list`：`chatMode = .list`，`listPath = []`
  - `chat`：会话模式；`lastSessionID` 存在则根换成它，否则新建根

## 5. 恢复与迁移

- `PanesEnvelope` v2 保存 `chatMode` / `listPath`；读到 v1：
  - 旧 `chatRoot == .session(id)` → 会话模式根 `.session(id)`；`.newSession` → 根新建
  - 旧 `selectedTab == .devices`：`chatMode = .list`，`listPath =` devicesPath 里的 `.session` / `.newSession`（`.device` 提进 `chatDevice`）
  - 旧 `selectedTab` 其它：会话模式，`listPath = []`
  - 可见 session 写入 `lastSessionID`
- 旧 `ChatShellSelection` 播种：`.session` → 会话模式；`.device` → 列表模式根 + `chatDevice`；`.newSession` → 新建会话根。
- 单测覆盖每条迁移路径。

## 6. 文件清单

| 文件 | 改动 |
|---|---|
| `Models/Chat/ShellPanesModel.swift` | `ChatTabMode`/`ChatTabRoot`/`ChatTabRoute`、`chatMode`/`listPath`、`ShellStartPage`、mutators、`visibleSessionId` |
| `Repositories/V2RestorationStore.swift` | v2 envelope + v1 迁移 + 旧 selection 迁移 |
| `Views/ChatShell/ShellTabsView.swift` | 4 tab（对话/Wiki/Files/Artifacts） |
| `Views/ChatShell/ChatShellView.swift` | 两模式根；列表内 `NavigationStack(path:)`；查看全部切模式；列表行 push |
| `Views/ChatShell/ChatSidebarView.swift` | 「最近」header 加「查看全部 ›」；tab shell 去掉设备区 |
| `Views/ChatShell/DashboardPageHosts.swift` | `NewSessionPageHost.showsMenuButton`；复用 Session/Device hosts |
| `Views/Settings/AccountSettingsSheet.swift` | 起始页面 row（无副标题） |
| `Assets.xcassets/anthropicon.files.imageset` | 官方 261123 `tray.svg` 原图，标签 Files |
| `Tests/ClientCoreTests/ShellPanesModelTests.swift` | 模式、列表 push、迁移、起始页 |
| `docs/handoff-list-chat-20261128.md` | 本文档 |

## 7. 验收

**功能**
- 查看全部：抽屉关闭 + 列表直接出现（只有一个动画；不是两层）
- 列表页左上角抽屉；列表 push 的会话/新建页系统返回
- 侧栏会话/新建：切到会话模式，只关抽屉
- Files 第 3 个 tab，标签 Files，官方 tray 图标
- 起始页面三选项冷启动各验一次
- 旧 panes / 旧 selection 恢复正确
- `visibleSessionId` 只认当前模式的会话；`shell.tabs.duplicate` 不再产生

**性能**
- 两种模式互斥，列表模式不挂会话页；会话模式不挂列表页
- `shell.tabs.frame` 中位 ≤120ms、无 >200ms 常态（b1699 基线 89/108）
- `scroll.frame` 无新增 hitch

## 8. 提交拆分

1. `feat(ios): 对话 tab 合并列表/会话两态`（637766edb / eb5a32058）
2. `refactor(ios): 对话 tab 改为互斥模式`（ae884986f）
3. `refactor(ios): 会话根 + 查看全部 push 列表`（3f0f19aad）
4. `fix(ios): 列表页左上角用抽屉、隐藏系统返回`（a04a4392a）
5. `feat(ios): 增加 Files tab 占位（官方 tray 图标）`（a7cefa460）
6. `refactor(ios): 查看全部改为切列表模式（列表内 push）`（本次）
7. `feat(ios): 起始页面设置（自动/会话/列表）`
8. `docs(ios): 合并方案与交接`

## 9. 风险

- 两模式互斥后，会话模式与列表模式切换会重建页面；真机看切换成本与切 tab 红线。
- 列表内 push 的会话页/新建页与列表根同处一个 NavigationStack；列表根有抽屉，push 页有返回。
- 列表模式不挂会话页，会话的实时更新仍由模型（共享）维护，回来时按冻结/补播逻辑处理。
- shell 是 L 级：切 tab 红线、恢复/深链、侧栏选择状态都要真机回归。
