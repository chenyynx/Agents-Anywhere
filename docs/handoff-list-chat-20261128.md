# 对话 tab 合并：会话根 + 列表 push（2026-11-28）

> 分支：`list`（原 `feat/list-chat`）= **list 线**（2026-11-28 pp 定，与 beta/next 平级、永不自动互合）；从 `next` 拉出，next 已合入 `feat/dashboard-library` @ `97749e69a`
> 范围：iOS only；不动 server / connector / web。

## 1. 目标 / 不做什么

**目标**
- 去掉 Devices tab；「对话」tab 同时承载会话和列表。
- 导航形态：**会话是根，查看全部 push 列表，列表里的点击都 push**。
- 侧栏去掉「设备」区，只留「查看全部」这一个列表入口。
- 设置新增「起始页面」：自动 / 会话 / 列表，默认自动。

**不做**
- 不做"列表和会话平级替换"（那是中间版本，已废弃）。
- 不做 PagePicture 快照 / 隐藏页停 body。
- 不动时间线/揭示/行高逻辑。
- 不保留旧的双 tab 壳（回退=按独立 commit revert）。

## 2. 导航模型

```
对话 tab
└─ 会话（根：会话页或新建页）
   └─ 查看全部 → push 列表（设备页）
        ├─ 点已有会话 → push 会话页
        └─ 新会话 → push 新建页 → 创建后替换成会话页
```

- **侧栏点会话**：替换根会话、清空栈（不 push）。
- **侧栏新建**：替换根为新建页、清空栈。
- **查看全部**：`chatPath = [.list]`，push 列表；返回回根会话。
- **列表点已有会话**：push `.session(id)` 到列表上；返回回列表 → 根。
- **列表开新会话**：push `.newSession` 到列表上；创建成功后替换成 `.session(id)`；返回回列表 → 根。
- 列表里切换设备只改 `chatDevice`，不 push。
- 根会话被列表/列表上的页面盖住时，根页面的 `shellTabVisible` 置 false：揭示/apply/cadence 冻结；返回时恢复。推入的会话用 `.devices` pane 角色，避免和根的 `.chat` 角色互相把可见集合清空。

## 3. 状态模型

```swift
enum ShellTab { case chat, wiki, artifacts }

enum ChatTabRoot: Codable, Equatable, Sendable {
    case session(V2SessionID)
    case newSession(workspace: String?)
}

enum ChatTabRoute: Codable, Equatable, Hashable, Sendable {
    case list
    case session(V2SessionID)
    case newSession(workspace: String?)
}

struct ShellPanesModel: Codable, Equatable, Sendable {
    var selectedTab: ShellTab = .chat
    var chatRoot: ChatTabRoot = .newSession(workspace: nil)
    var chatPath: [ChatTabRoute] = []
    var chatDevice: V2ConnectorID?
    var lastSessionID: V2SessionID?
}
```

- `visibleSessionId(obscured:)`：栈顶是 `.session` 返回它；栈空且根是 `.session` 返回根；列表/新建在顶上时返回 nil。
- mutators：`openChatSession`（侧栏：换根+清栈）、`startNewChat`（侧栏：根新建+清栈）、`showList`（`chatPath = [.list]`）、`openDevice`（列表+设备）、`pushChatSession`/`pushNewChat`（列表行）、`finishNewChat`（新建页换成会话页）。
- `lastSessionID` 在打开/推入会话时写入，删除/归档时清理。

## 4. 设置项：起始页面

- 位置：设置 → 通用 → 起始页面。
- 值：自动 / 会话 / 列表，默认自动；存储 `aa.shell.startPage`。
- 只在冷启动/恢复应用一次：
  - `auto`：恢复 `chatRoot` + `chatPath`
  - `list`：`chatPath = [.list]`（根会话在下面，返回可见）
  - `chat`：`chatPath = []`；`lastSessionID` 存在则根换成它，否则保留新建根

## 5. 恢复与迁移

- `PanesEnvelope` v2 保存 `chatRoot`/`chatPath`；读到 v1：
  - 旧 `chatRoot == .session(id)` → 根 `.session(id)`；`.newSession` → 根 `.newSession`
  - 旧 `selectedTab == .devices`：`chatPath = [.list] + devicesPath`（`.device` 提进 `chatDevice`，`.session`/`.newSession` 原序 push）
  - 旧 `selectedTab` 其它：`chatPath = []`
  - 可见 session 写入 `lastSessionID`
- 旧 `ChatShellSelection` 播种：`.session` → 根会话；`.device` → 根新建 + `chatPath [.list]` + `chatDevice`；`.newSession` → 默认根。
- 单测覆盖每条迁移路径。

## 6. 文件清单

| 文件 | 改动 |
|---|---|
| `Models/Chat/ShellPanesModel.swift` | `ChatTabRoot`/`ChatTabRoute`/`chatRoot`/`chatPath`、`ShellStartPage`、mutators、`visibleSessionId` |
| `Repositories/V2RestorationStore.swift` | v2 envelope + v1 迁移 + 旧 selection 迁移 |
| `Views/ChatShell/ShellTabsView.swift` | 3 tab；去掉 devices 页；chat 页承载整个栈 |
| `Views/ChatShell/ChatShellView.swift` | 会话根 + `NavigationStack(path:)`；查看全部 push；列表行 push；根可见性门 |
| `Views/ChatShell/ChatSidebarView.swift` | 「最近」header 加「查看全部 ›」；去掉设备区（tab shell） |
| `Views/ChatShell/DashboardPageHosts.swift` | 复用 SessionPageHost / DevicePageHost |
| `Views/Settings/AccountSettingsSheet.swift` | 起始页面 row |
| `Diagnostics/ClientDiagnosticsLog.swift` | `shell.tabs.state` 字段 root/path/last |
| `Tests/ClientCoreTests/ShellPanesModelTests.swift` | 根/栈、迁移、起始页 |
| `docs/handoff-list-chat-20261128.md` | 本文档 |

## 7. 验收

**功能**
- 侧栏会话 → 根会话（无 push）；侧栏新建 → 根新建
- 查看全部 → push 列表；返回回根会话
- 列表点已有会话 → push 会话页；返回回列表 → 根
- 列表开新会话 → push；创建后替换成会话页；返回回列表
- 侧栏无设备区；只有查看全部一个列表入口
- 起始页面三选项冷启动各验一次
- 旧 panes / 旧 selection 恢复正确
- `visibleSessionId` 只认栈顶/根会话；`shell.tabs.duplicate` 不再产生

**性能**
- 根会话被盖住时 `shellTabVisible=false`：揭示/apply/cadence 冻结
- 推入会话用 `.devices` pane 角色，可见集合不被根页面的 false 清空
- `shell.tabs.frame` 中位 ≤120ms、无 >200ms 常态（b1699 基线 89/108）
- `scroll.frame` 无新增 hitch

## 8. 提交拆分

1. `feat(ios): 对话 tab 合并列表/会话两态`（637766edb / eb5a32058，push 初版）
2. `refactor(ios): 对话 tab 改为互斥模式`（ae884986f，中间版本）
3. `refactor(ios): 会话根 + 查看全部 push 列表`（最终形态）
4. `feat(ios): 起始页面设置（自动/会话/列表）`
5. `docs(ios): 合并方案与交接`

## 9. 风险

- 根会话在栈底常驻；被盖住时靠 `shellTabVisible=false` 冻结，仍需真机确认 reveal/apply 不再跑。
- 列表上的会话页和根会话可能同时存在（根隐藏、推入可见）；`.devices` 角色用于区分 cadence 可见集合。
- shell 是 L 级：切 tab 红线、恢复/深链、侧栏选择状态都要真机回归。
- 没有"并行两个会话"以外的 tab 语义；根始终是一个会话/新建页。
