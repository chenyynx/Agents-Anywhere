# 手机控制 v1（Phone Bridge）设计

> 状态：设计草案 · 2026-11-28
> 基线：`core`
> 关联：`contracts/phone-bridge/v1/`、[OpenMinis/iCTRL](https://github.com/OpenMinis/iCTRL)

## 1. 目标

让 AA 会话里的 Agent 能操作一台**侧载了 iCTRL** 的 iPhone：

- 不依赖 Tailscale、公网 IP、小火箭
- iCTRL 的 **Remote Access 保持关闭**，只监听 `127.0.0.1:8200`
- v1 先支持 Claude（in-process MCP）；Codex / DSH 用本地端口 + 官方 CLI
- UI 复用设置页现有组件与 `SettingsStyle` token，不新增设计 token

## 2. 非目标（v1 不做）

- 远程 MCP（复制 URL 给外部 AI）→ v1.1
- Tailscale transport
- 视频流 / 远程桌面
- Android
- 任意端口转发（只允许 `8200`）
- 修改 iCTRL 源码

## 3. 架构

```
Agent（Claude Code / Codex）
  ├─ Claude: mcp__phone__*（in-process MCP）
  └─ 任意 runtime: ictrl_rpc.py --host 127.0.0.1:18200
        │
        ▼
Connector PhoneBridgeServer（127.0.0.1:18200，仅 loopback）
        │ WSS relay
        ▼
Server PhoneBridgeBroker（多租户、鉴权、路由、限额）
        │ WSS
        ▼
AA iOS App PhoneBridgeClient（后台保活）
        │ TCP 127.0.0.1:8200
        ▼
iCTRL runner（原版，未修改）
```

**为什么这样：**

- 手机和 connector 都在 NAT 后面，只能主动连 Server；Server 是唯一会合点
- iCTRL 的配对与 HMAC 加密在「connector 的 iCTRL 客户端 ↔ 手机 runner」之间端到端，Server 只搬密文字节
- AA App 已有 `KeepAliveCoordinator`（静音音频 / 定位），后台保活复用同一条命
- 本地端口让官方 `ictrl_rpc.py` / C CLI 直接可用，不重写协议

## 4. 协议 v1

### 4.1 接口

```
POST /api/v2/connectors/{connectorId}/phone/bridges
  body: { deviceId?, port?, purpose? }   # deviceId 省略时要求仅一台在线
  resp: { bridgeId, deviceId, connectorId, port, relayToken, expiresAt }

GET  /api/v2/phone/devices                  # user token
GET  /api/v2/connectors/{connectorId}/phone/devices   # connector token
  resp: { devices: [{ deviceId, name, appVersion, bridgeVersion, online, lastSeen }] }

WS   /api/v2/phone/ws?ticket=...
  # 手机端；ticket scope = phone

WS   /api/v2/connectors/{connectorId}/phone/{bridgeId}/relay?token=...
  # connector 端；Authorization: Bearer <connector access token>
  # 只有 60s 的 relayToken 在 query，access token 不进请求行/日志
```

### 4.2 帧

手机端与 connector 端使用方向化帧（connector 帧无 `bridgeId`），Server 做配对转发：

```json
{"type":"ready","bridgeId":"...","port":8200}
{"type":"open","bridgeId":"...","port":8200}
{"type":"data","seq":1,"data":"<base64>"}
{"type":"close","reason":"eof|timeout|error"}
{"type":"error","code":"...","message":"..."}
{"type":"ping"} / {"type":"pong"}
```

### 4.3 限额

- 单帧 ≤ 1 MiB；超过回 `error(bad_frame)`，不截断
- 空闲 5 分钟断开
- 端口白名单 `[8200]`；Server 校验、手机侧硬校验；Connector 只发送配置的 target port
- 每用户并发 bridge 上限（v1: 8）；每设备 4 条活跃 bridge
- **v1 要求 Server 单 worker**（默认 `AGENT_SERVER_WORKERS=1`）；多 worker 时 `/phone/*` 直接 503（WS 1013），不静默变成「phone is offline」
- Server 会 base64 解码校验大小后重编码；`seq` 只透传，不用于排序（单 WS 顺序由发送锁保证）

### 4.4 鉴权

- 手机端：`/ws-ticket` 增加 `scope.phone`，ticket 一次性、短 TTL
- Connector 端：`Authorization: Bearer <connector access token>` + `relayToken`（单 bridge、短 TTL）
- Server 校验 `user_id`、`connector_id` 与 relay token 绑定；phone 的 `deviceId` 由手机自报，作用域限于该 user
- **v1 没有设备 token/撤销端点**：手机侧「允许 AA 控制本机」开关就是授权，关掉即不再连；细粒度设备 token/撤销列 v1.1

### 4.5 状态机

```
idle → connecting → open → closing → closed
```

- v1 不做「同一条 bridge 的透明重连」：relay 断开即关闭本地 TCP，由 iCTRL 客户端/agent 自行重试；已发出的 tap 可能已执行，重试前先 `logs`（官方 skill 的规则）
- 手机离线：Server 返回 409 `phone is offline`，Connector 不重试
- 手机重连：新 bridge，不复用旧 `bridgeId`
- App 切后台：保活继续；保活失效 → bridge 关闭，状态可观测

## 5. 数据模型

- v1 全部在 Server 进程内：`(user_id, device_id) -> PhoneConnection`、`bridge_id -> PhoneBridge`
- 无数据库表、无 Redis、无 `revoked_at`、无审计记录；Server 重启后手机重连即可
- v1.1 再补设备表、撤销、审计（`phone.bridge.open/close` 含 user/device/connector/port/bytes/duration）

## 6. Server 改动

| 文件 | 改动 |
|---|---|
| `server/agent_server/infra/phone_bridge_broker.py` | 新增；双 WS 配对、发送锁、TTL、单 worker 标记 |
| `server/agent_server/api/phone_bridge.py` | 新增；3 个 HTTP 接口 + 手机 WS + connector relay WS |
| `server/agent_server/core/protocol.py` | 改；`ProtocolWsTicketScope` 增加 `phone`，bridge 模型 |
| `server/agent_server/api/client_ws.py` | 改；ticket scope 校验 |
| `server/agent_server/app.py` | 改；broker 生命周期、多 worker 503 标记 |
| `server/tests/test_phone_bridge_api.py` / `test_phone_bridge_broker.py` | 新增；配对/越权/端口白名单/TTL/多 worker |

约束：

- `core` 不导入外层；API 层只做解析和鉴权，状态在 `infra`
- 无数据库/Redis（v1 单进程）；持久化/多 worker 路由列 v1.1
- 能力字段 `phoneBridge` 尚未实现；iOS 通过连接状态区分「未连接/等待电脑」

## 7. Connector 改动

| 文件 | 改动 |
|---|---|
| `connector/connector/server/phone_bridge.py` | 新增；仿 `terminal_relay.py`：连 Server relay WS，收 `open/data/close` |
| `connector/connector/local/phone_bridge.py` | 新增；`127.0.0.1:18200` TCP listener，每个连接开一条 bridge |
| `connector/connector/server/client.py` | 改；启动/停止 runner、把 runner 挂到 runtime host |
| `connector/connector/core/config.py` | 改；`phone_bridge_enabled` / `listen_host` / `listen_port` / `device_id` / `target_port` + env overlay |
| `connector/connector/core/control_config.py` / `cli.py` | 改；配置保存/CLI/env 不丢 phone 字段 |
| `connector/tests/test_phone_bridge.py` | 新增；relay、本地端口、env、配置保留 |

v1 开启方式：`~/.agents-anywhere-*/connector.json` 写 `"phoneBridgeEnabled": true`，或设置 `AGENT_CONNECTOR_PHONE_BRIDGE_ENABLED=1`。桌面 Connector 设置页的开关列 v1.1；`save_config` 已保留未知的新字段，手改不会被桌面保存抹掉。

## 8. iOS 改动

| 文件 | 改动 |
|---|---|
| `ios/Agents Anywhere/Agents Anywhere/PhoneBridge/PhoneBridgeClient.swift` | 新增；WS 连 Server + `NWConnection` 拨 `127.0.0.1:8200`，帧编解码、重连 |
| `ios/Agents Anywhere/Agents Anywhere/Views/Settings/PhoneControlSettingsView.swift` | 新增；设置页 |
| `ios/Agents Anywhere/Agents Anywhere/Views/Settings/AccountSettingsSheet.swift` | 改；加入口行 |
| `ios/Agents Anywhere/Agents Anywhere/Stores/AppState.swift` | 改；后台保活判据包含 phone bridge |
| `ios/Agents Anywhere/Agents Anywhere/Business/V2ClientServices.swift` | 改；phoneBridge 生命周期 |
| `ios/Package.swift` | 改；把 `PhoneBridge` 加入 ClientCore sources |
| `ios/Tests/ClientCoreTests/RealtimeTests.swift` | 改；phone scope/URL 测试（客户端状态机测试 v1.1） |

## 9. UI 规格（复用现有 token）

> 不新增颜色、字体、间距常量。全部使用 `SettingsStyle` 与现有组件。

### 9.1 入口

`AccountSettingsSheet.connectionSection` 中，Connectors / Server 之后：

```swift
SettingsRowDivider()
SettingsNavigationRow(
    icon: "anthropicon.mobilePhone",
    title: String(localized: "手机控制"),
    value: phoneStatusText,          // 已连接 / 未连接 / 未安装
    destination: PhoneControlSettingsView()
)
```

### 9.2 详情页

```swift
SettingsScreen(title: String(localized: "手机控制")) {
    SettingsSection(footer: String(localized: "需要先在手机上安装 iCTRL。AA 只转发加密字节，不读取屏幕内容。")) {
        SettingsToggleRow(
            icon: "anthropicon.mobilePhone",
            title: String(localized: "允许 AA 控制本机"),
            subtitle: String(localized: "通过本机 iCTRL 服务操作 App"),
            isOn: $enabled
        )
    }

    SettingsSection(String(localized: "状态")) {
        SettingsRowLabelContent(icon: "anthropicon.codeBlock",
                                title: String(localized: "iCTRL 服务"),
                                value: ictrlStatusText, showsChevron: false)
        SettingsRowDivider()
        SettingsRowLabelContent(icon: "anthropicon.cloud",
                                title: String(localized: "连接"),
                                value: connectionText, showsChevron: false)
        SettingsRowDivider()
        SettingsRowLabelContent(icon: "anthropicon.computer",
                                title: String(localized: "当前电脑"),
                                value: currentComputerText, showsChevron: false)
        SettingsRowDivider()
        SettingsDisclosureRow(icon: "anthropicon.arrowClockwise",
                              title: String(localized: "测试连接"),
                              value: latencyText,
                              showsChevron: false) { testConnection() }
    }

    // v1 shows the current computer only. A persisted authorized-computer
    // list needs the device registry (v1.1); no fake rows in the meantime.

    SettingsSection(String(localized: "高级")) {
        SettingsNavigationRow(icon: "anthropicon.research",
                              title: String(localized: "诊断日志"),
                              destination: DiagnosticsLogSettingsView())
    }

    SettingsSection(String(localized: "帮助")) {
        SettingsDisclosureRow(icon: "anthropicon.info",
                              title: String(localized: "iCTRL 未安装？查看安装指南"),
                              showsChevron: true) { openInstallGuide() }
        SettingsRowDivider()
        SettingsDisclosureRow(icon: "anthropicon.lockShield",
                              title: String(localized: "什么是手机控制？"),
                              showsChevron: true) { openExplainer() }
    }
}
```

### 9.3 状态文案

| 状态 | 入口 value | 连接行 |
|---|---|---|
| 关闭 | `未连接` | `已关闭` |
| 开启、iCTRL 未安装 | `未连接` | `未检测到`（iCTRL 服务行） |
| 等待电脑 | `等待电脑` | `等待电脑` |
| 已连接 | `已连接` | `已连接` |
| 连接中 | `连接中` | `连接中…` |
| 错误 | `未连接` | 错误文本 |

### 9.4 设计约束

- 字体：只用 `SettingsStyle.text(size)`；标题 16、副标题/值 15、section header 14（或现有 `headerFont`）
- 颜色：只用 `SettingsStyle.background/card/ink/secondary/header/icon/hairline/controlTint`
- 布局：只用 `SettingsScreen` / `SettingsSection` / `SettingsRowContainer` / `SettingsRowDivider`
- 行：只用 `SettingsToggleRow` / `SettingsRowLabelContent` / `SettingsDisclosureRow` / `SettingsNavigationRow` / `SettingsMenuRow`
- 图标：只用现有 `anthropicon.*`（`mobilePhone`, `computer`, `cloud`, `clock`, `key`, `lockShield`, `arrowClockwise`, `trash`, `eye`, `warning`, `copy`, `check`, `settings`）
- 危险操作：沿用现有 sign-out 行的 `.foregroundStyle(.red)` 写法
- 不新增 `SettingsStyle` 常量；确需新语义色时先复用 `AppTheme` 现有色
- 本地化：新增文案进 `Localizable.strings`（中/英同步）

## 10. MCP + Skill

### 10.1 工具面

```
phone_devices()                         → 在线手机（connector 认证）
phone_pair()                            → 首次配对（手机点 Allow）
phone_skill()                           → /skill 全文
phone_schema(method?)                   → /schema
phone_call(method, params)              → 通用 JSON-RPC
```

### 10.2 实现

- 文件：`connector/connector/runtimes/claude/sdk/phone_tool.py`，仿 `title_tool.py`
- 用 `create_sdk_mcp_server(name="phone", version="1.0.0", tools=[...])`
- MCP server 持有 iCTRL 客户端（官方 `ictrl_rpc.py` 的协议逻辑），token 存 connector 安全存储；每次调用只新建 localhost HTTP 连接，不再起 Python 进程
- `client.py` 的 `mcp_servers` 从单服务器改为合并 `title` + `phone`
- `phone_skill` 返回设备当前版本手册，避免手册漂移
- 权限：v1 以手机侧「允许 AA 控制本机」总开关为授权，`mcp__phone__*` 在 connector 侧自动放行，避免每 tap 弹审批；细粒度会话授权/只读模式列 v1.1

### 10.3 Skill

- 不把 20+ 方法做成 MCP tool
- `phone_skill` 是唯一手册来源；MCP system prompt 只写「先 phone_skill，再 phone_call」
- Codex / DSH：v1 用本地端口 + 官方 CLI；后续再接各自 MCP

## 11. 测试计划

### 11.1 契约

- JSON Schema 校验所有 fixtures
- Connector 测试用 `jsonschema` 校验全部 fixtures；Server/iOS 直接按同一份 `$defs` 实现（v1 未在两端重复加载 fixture）

### 11.2 Server

- 手机 WS + connector WS 配对
- 跨用户越权拒绝
- 端口白名单（8200 通过，22/80 拒绝）
- attach 过期（410）与同 bridge 二次 attach（409）
- relay token 绑定 connector/user；同一 bridge 二次 attach 被拒绝（防重放）
- 慢消费者/背压：v1 用阻塞 send，列为 v1.1
- 手机离线/重连
- TTL/租约

### 11.3 Connector

- relay 重连（指数退避）
- 本地 TCP 并发连接
- 单帧上限
- Server 断开时本地连接关闭
- 端口不允许时拒绝

### 11.4 iOS（v1 实际覆盖）

- `V2RealtimeScope.phone` 编码、`/api/v2/phone/ws` URL/ticket、`PhoneBridgeFrame` 解析（已测）
- `PhoneBridgeClient` 状态机、前后台重连、发送队列/Tunnel 生命周期：**v1.1 补**（本机无 Swift 工具链，v1 只做静态审查）
- 设置开关持久化按 `V2RestorationStore.scopeKey` 分账号/server
- 诊断 kind 只在状态变化时写（`phone.bridge.connect/error`）

### 11.5 E2E（真机）

1. iCTRL Remote Access **关闭**
2. AA App 切后台
3. connector `curl 127.0.0.1:18200/skill` 成功
4. `ictrl_rpc.py pair` → 手机点 Allow → `device_info`
5. `page_source` / `tap` / `type` 成功
6. 连续 30 分钟 soak，无断线
7. 强杀 AA App → 10 秒内重连
8. 端口 22/80 不可达
9. MCP 与 CLI 同任务各 5 次：成功率、耗时、重试

### 11.6 CI

```
cd server && uv run ruff check . --exclude .venv && uv run pytest -q
cd connector && uv run ruff check connector tests && uv run pytest -q
iOS: 单测 + unsigned IPA
```

## 12. 发布

- Server：路由常驻（无手机连接时惰性）；能力位 v1.1（v1 用连接状态判断）
- Connector：配置默认 off（`phoneBridgeEnabled` / env）
- iOS：设置默认 off；开关开启才连
- 版本：跨端接口变化按 `2.x.0` 升 MINOR；已统一升 `2.4.0`（Server/Connector/iOS/Web/Desktop/Android/DSH；Android versionCode 13）
- 文档：`docs/phone-control-v1.md` + README 相关段落 + release notes
- 回滚：关手机/Connector 开关即恢复；Server 路由可整体下线，不影响现有会话

## 13. 验收

- 三端单测 + CI 绿
- 真机 E2E 全过
- 30 分钟 soak 无断线
- 端口白名单/越权测试通过
- MCP 与 CLI 对比数据达标
- 设置页只用现有 token，视觉与现有设置页一致

## 14. 风险

| 风险 | 缓解 |
|---|---|
| iOS 后台保活被音频打断 | 降级定位；状态可见；自动重连；必要时把 bridge 放进 iCTRL runner（fork 方案） |
| 开启手机控制等于开启后台保活 | 设置页 footer 已说明；永久错误时不再启动保活（`isFatalError`） |
| Server broker 成为瓶颈 | 单 bridge/每用户限额；背压与多实例列 v1.1 |
| 开放端口的安全面 | 只允许 8200；loopback；手机侧开关；iCTRL 自身配对；设备 token/审计 v1.1 |
| iCTRL 版本漂移 | `phone_skill` 从设备取手册；`/schema` 版本校验 |
| App Store 审核 | AA App 只用公开 API；iCTRL 侧载；文案定位为开发者/自动化工具 |
| 本地端口被本机其他进程使用 | 仅 loopback；文档说明；v1 无 per-install secret（v1.1） |
| iCTRL 把隧道来源显示为「本机/USB」 | 隧道终止在手机 loopback，这是不修改 iCTRL 的必然代价；配对仍需手机点 Allow |
| 配对指纹提示晚于手机弹窗 | v1 以手机 Allow 为准；指纹只在失败排查时使用 |
| Server 多 worker 时手机与 connector 落在不同进程 | v1 要求 `AGENT_SERVER_WORKERS=1`；v1.1 加 Redis 路由 |

## 15. 待定


- 远程 MCP：v1.1
- 多手机：v1 单活跃设备，列表可见；切换手机会覆盖本地 token，需要重新配对（v1.1 按 device id 存）
- Codex / DSH 的 MCP 接入：v1 用本地端口 + CLI
