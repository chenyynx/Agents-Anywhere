# 对话 tab 合并：列表 / 会话两态（2026-11-28）

> 分支：`feat/list-chat`（从 `next` 拉出，next 已合入 `feat/dashboard-library` @ `97749e69a`）
> 范围：iOS only；不动 server / connector / web。

## 1. 目标 / 不做什么

**目标**
- 去掉 Devices tab；「对话」tab 内置两种模式：**列表模式**（现设备页）/ **会话模式**（现对话页）。
- 同一时刻只有一个 session page，从根上消除同会话双挂（第二份 body/refresh/reveal/键盘）。
- 侧栏「最近」标题行 `⋯` 后加「查看全部 ›」→ 切到列表模式。
- 设置新增「起始页面」：自动 / 会话 / 列表，默认自动。

**不做**
- 不做 PagePicture 快照 / 隐藏页停 body（合并后没有第二个 session page）。
- 不动时间线/揭示/行高。
- 不保留旧的双 tab 壳（回退=按独立 commit revert，不做双壳开关）。

## 2. 状态模型

交互照搬现在的设备页：**列表是根，会话是 push，左上角系统返回**。

```swift
enum ShellTab { case chat, wiki, artifacts }        // 对话保持叫「对话」

enum ChatTabRoute: Hashable, Codable, Sendable {
    case device(V2ConnectorID)
    case session(V2SessionID)
    case newSession(workspace: String?)
}

struct ShellPanesModel {
    var selectedTab: ShellTab = .chat
    var chatPath: [ChatTabRoute] = []              // 空 = 列表模式（设备页根）
    var chatDevice: V2ConnectorID?                 // 根列表展示哪台设备（原 devicesDevice）
    var lastSessionID: V2SessionID?                // 起始页面=会话 的落点
}
```

- 删除 `ShellChatRoot`；`ShellDevicesRoute` 改名/合并为 `ChatTabRoute`；`devicesPath` → `chatPath`。
- 模式是派生值：`chatPath.isEmpty` = 列表模式；栈顶 `.session` = 会话模式。
- `visibleSessionId(obscured:)`：`selectedTab == .chat` 且 `chatPath.last == .session(id)`。
- mutators：`showList(device:)`（清空 path）、`openDevice(id)`、`openSession(id)`（path = `[.session(id)]`）、`startNewSession(workspace:)`、`startNewChat()`。
- `openSession` 同时写 `lastSessionID`。

## 3. UI / 交互

- tab bar：3 项（对话 / Wiki / Artifacts）。
- 对话 tab = `NavigationStack(path: $panes.chatPath)`：
  - 根 → `DevicePageHost(connectorId: chatDevice)`（列表模式）
  - `.session(id)` → `SessionPageHost(paneRole: .chat)`（push；系统返回回列表）
  - `.newSession(workspace)` → `NewSessionPageHost`
- 列表模式入口/出口：
  - 列表点会话 → push `.session(id)`
  - 列表 FAB / 项目菜单新建 → push `.newSession(workspace)`
  - 侧栏「最近」header：`最近  [Spacer]  ⋯  查看全部 ›`（仅会话模式显示；13pt 主文字色 + caret）
    → 关抽屉 + `showList()`（pop 到根）
  - 侧栏设备行 → `openDevice(id)`（列表模式 + 该设备）
  - 侧栏会话行 → `openSession(id)`
  - 通知/深链 → `selectedTab = .chat` + `chatPath = [.session(id)]`
- 会话页左上角：**系统返回**（`NavigationStack` 的 `<`，和现在设备页完全一样）→ 回列表。
- 列表模式是根，无返回；「查看全部」只是从侧栏快速 pop 到根。

## 4. 设置项：起始页面

- 位置：设置根页新增 `General` 分组，或放进 `Appearance & display`；行内三选一。
- 值：`初始页面 = 自动 | 会话 | 列表`，默认**自动**。
- 存储：`aa.shell.startPage`（`auto|chat|list`），`@AppStorage`；`enum ShellStartPage: String { auto, chat, list }`。
- 只在大启动/恢复时应用；使用中切 tab 不重置：
  - `auto`：恢复的 `chatPath`
  - `list`：`chatPath = []`
  - `chat`：`lastSessionID` 存在 → `chatPath = [.session(id)]`，否则 `[]`
- `lastSessionID` 在每次打开会话时写入（不能只靠 `chatPath` 恢复值，上次停在列表时它是空）。

## 5. 恢复与迁移

- `PanesEnvelope` 接受 v1（旧 `ShellPanesModel`）和 v2；读到 v1 迁移：
  - `chatRoot == .session(id)` → `chatPath = [.session(id)]`
  - 否则 `devicesPath.last == .session(id)` → `chatPath = [.session(id)]`
  - 否则 `devicesPath.last == .newSession(ws)` → `chatPath = [.newSession(ws)]`
  - 否则 `chatPath = []`
  - `chatDevice = devicesDevice`；`lastSessionID =` 迁移出的 session
  - `selectedTab == .devices` → `.chat`
- 旧 `ChatShellSelection` 迁移：`.session(id)` → `chatPath = [.session(id)]`；`.device(id)` → `[]` + `chatDevice = id`；`.newSession` → `[]`（或保持 `.newSession`，实现时按旧行为定）
- 保存改为 v2 envelope。
- 单测覆盖每条迁移路径。

## 6. 文件清单

| 文件 | 改动 |
|---|---|
| `Models/Chat/ShellPanesModel.swift` | `ChatTabRoute`/`chatPath`、`ShellStartPage` 状态/mutators/`visibleSessionId` |
| `Repositories/V2RestorationStore.swift` | v2 envelope + v1 迁移 + 旧 selection 迁移 |
| `Views/ChatShell/ShellTabsView.swift` | 3 tab；去掉 devices 页；chat 页按 mode 渲染；`duplicateSessionAcrossTabs` 删除 |
| `Views/ChatShell/ChatShellView.swift` | 对话 tab 根改为设备页 + `chatPath` 栈；`openSession`/`openDevice`/`startNewSession`；深链 |
| `Views/ChatShell/ChatSidebarView.swift` | 「最近」header 加「查看全部 ›」；设备行→`openDevice`；会话行→`openSession` |
| `Views/ChatShell/DashboardPageHosts.swift` | 复用 `SessionPageHost`/`DevicePageHost`；paneRole 只留 `.chat` |
| `Views/Settings/*` | 起始页面 row + picker |
| `Diagnostics/ClientDiagnosticsLog.swift` | kind 文档：`shell.tabs.duplicate` 退休；`shell.tabs.state` path 字段更新 |
| `Tests/ClientCoreTests/ShellPanesModelTests.swift` | 模式迁移、visibleSessionId、起始页面、恢复 |
| `docs/handoff-list-chat-20261128.md` | 本文档 |

## 7. 验收

**功能**
- 列表 ↔ 会话切换（查看全部 / 侧栏设备 / 侧栏会话 / 深链 / 新建）
- 起始页面三选项冷启动各验一次
- 旧 panes / 旧 selection 恢复后落在正确模式
- 同会话只出现一个 `session.page.appear` pane；不再有 `shell.tabs.duplicate`
- wiki/artifacts tab 正常

**性能（红线）**
- `shell.tabs.frame`：中位 ≤120ms，无 >200ms 常态（b1699 基线 89/108）
- 滑抽屉时只有一个 session body；`tab.stack` / `scroll.frame` 无新增 hitch
- 列表/会话互斥，列表页不持有 session 模型

**回归**
- 项目侧栏/项目选择/项目编辑器/归档 sheet
- 会话页返回、滚动位置、键盘、开新会话、通知深链
- 恢复并发（两个 tab 同名会话的旧快照）

## 8. 提交拆分（每步可回退）

模型字段和壳的 104 处引用拆不开（改字段会立刻破坏编译），所以第 1 笔把
模型、恢复迁移、壳、侧栏入口一起做：

1. `feat(ios): 对话 tab 合并列表/会话两态（chatPath 栈 + 迁移）`
2. `feat(ios): 起始页面设置（自动/会话/列表）`
3. `docs(ios): 合并方案与交接`

## 9. 风险

- shell 是 L 级：切 tab 红线、恢复/深链、侧栏选择状态都要真机回归。
- 合并后没有"并行两个会话"；这是明确取舍（性能优先）。
- 会话页左上角返回入口未定，影响"从会话回列表"的顺手程度。
