# 任务单：AA 时间线浏览器卡片（远程浏览器接管）

- 日期：2026-10-23
- 级别：L（跨端：iOS + connector + 新增运行时服务；含鉴权与生命周期）
- 分支：`feat/timeline-browser-card`（基于 `origin/dev` `9ad2abe1`；不合 dev，出包走分支）
- 关联参考：Muse 的「打开浏览器」卡片（pp 截图，2026-10-23）
- 调研方式：三路只读代码调研（iOS / connector / server），行号为 2026-10-23 快照，实现时逐条复核

---

## 1. 目标

在 AA 会话时间线里出现一张**浏览器卡片**；点击后全屏进入**实时画面**，pp 可以直接点按、滚动、输入、扫码登录；同一时刻 agent（Claude）通过 CDP 操作**同一个浏览器**；登录态持久保存在服务器浏览器 profile 里，跨会话复用。

产品语义：

- 卡片 = 「agent 打开了一个浏览器」的可见凭据，和子代理卡、工具卡同级
- 点击 = 远程接管（像 Muse 的「打开浏览器」）
- agent 侧 = 同一浏览器的 CDP 控制端，不改页面、不另开无头实例

---

## 2. 非目标（首版不做）

- 地址栏 / 多标签 / 书签 / 历史记录
- 卡片内直接预览画面缩略图（首版卡片只显示标题、域名、状态、打开按钮）
- Android / Web 端渲染（首版只做 iOS；服务端契约不变，其他端退化为普通工具行）
- 原生画面串流（首版复用 Neko 的 WebRTC 页面，不做自研 screencast）
- Cookie 导出给 App 或第三方
- 多用户共享同一浏览器

---

## 3. 架构

```
iPhone (AA)
  │  时间线卡片（原生 SwiftUI）
  │  点击 → fullScreenCover
  ▼
WKWebView ──HTTPS/WSS──> nginx(8443, browser.pipicore.cn)
                              │ auth_request（校验 cookie）
                              ▼
                        browser-gateway (127.0.0.1:8090)
                              │ 运行时适配（Neko 默认 / Steel 备选）
                              ▼
                  Chrome 运行时（Steel 容器 或 Neko 容器）
                              │
                              ├─ Chromium（CDP 127.0.0.1:9222）
                              └─ profile volume（登录态持久）

Claude 会话 (connector)
  │  MCP 工具 browser_open
  ▼
browser-gateway ──> 确保容器/页面就绪，签发一次性 URL
  │  返回 { browserId, liveUrl, cdpUrl }
  ▼
agent 用 Playwright 通过 cdpUrl 操作同一 Chromium
```

关键决定：

1. **浏览器运行时与 agent 控制端共用同一个 Chromium 实例**（运行时画面 + CDP 端口），pp 看到的和 agent 操作的是同一页面。
2. **卡片不新增 timeline 类型**：复用 `type="tool"` + `content` 自由 JSON，iOS 按 `content.server == "browser"` 识别；不改 server enum、不改数据库、不改契约、旧客户端退化为普通工具行。
3. **默认运行时 = Neko（pp 2026-10-23 定）**：WebRTC 约 30fps，触控/滚动延迟最低，点开接管的手感最好。代价是 web 端为完整远程桌面客户端、CDP 需改 Chromium 启动参数；UI 精简与 WKWebView 兼容性在 M0 实测。
4. **Steel 作为保底**：自带会话、`persist`/`userDataDir`、CDP 与专为 iframe 嵌入设计的 live 页（WSS/TCP 更稳、UI 干净）。若 Neko 在 iOS WKWebView 或香港线路上不可接受，gateway 换 adapter 切 Steel，connector 与 iOS 不用改。
5. **鉴权走服务端签发的短时 token**：一次性 open token（fragment，不落访问日志）→ 换取 HttpOnly cookie → nginx `auth_request` 同时保护页面与 WSS。不复用 7 天用户 token 到 URL（参照终端 WS 的 query token 先例，但更严格）。

---

## 4. 三端改动清单

### 4.1 新增：浏览器运行时（运行时抽象；Neko 默认 / Steel 备选）

位置：`/data/browser-runtime/`（docker compose + 自定义镜像）

**默认：Neko（`m1k1o/neko`，Apache-2.0）**

- 基础镜像：`ghcr.io/m1k1o/neko/chromium:latest`，自定义 Dockerfile（5 行）覆写 `/etc/neko/supervisord/chromium.conf`，启动参数加 `--remote-debugging-port=9222` 与 `--remote-debugging-address=0.0.0.0`
- 端口：`127.0.0.1:8080:8080`（Neko Web）、`127.0.0.1:9222:9222`（CDP）
- 卷：`/data/browser-runtime/neko-profile:/home/neko/.config/chromium`（登录态持久）
- 环境：`NEKO_SCREEN=720x1280@30`（竖屏手机尺寸，省 CPU）；`NEKO_PASSWORD`/`NEKO_PASSWORD_ADMIN` 随机值落 `0600`
- 资源：`mem_limit=2g`、`cpus=2`；单会话常驻约 0.6–1G
- 验证点（M0 必测）：
  1. Neko 客户端在 iOS WKWebView 中的 WebRTC 播放、键盘（含中文输入）、触摸/拖拽
  2. Neko 客户端 UI 精简：能否隐藏聊天/设置等远程桌面元素，只留画面
  3. CDP 端口可用，Playwright `connectOverCDP` 能操作同一 Chromium
  4. profile 卷跨容器重启保留登录态

**备选：Steel Browser（`steel-dev/steel-browser`，Apache-2.0）**

- 镜像：`ghcr.io/steel-dev/steel-browser`（API + UI 合一，Docker）
- 会话创建参数：`persist=true` + `userDataDir=/data/browser-runtime/profile`（登录态持久）
- 端口映射：
  - `127.0.0.1:3000:3000`（Steel API + live 页，nginx/gateway 访问）
  - `127.0.0.1:9223:9223`（Steel 提供的 CDP/调试口，仅本机 agent 可用）
- live view：`/sessions/:id/live`（Steel Session Player，iframe 可用，自带鼠标/键盘转发）
- 适用条件：Neko 在 WKWebView 或香港线路上不可接受时启用；gateway 只需换 adapter，connector/iOS 不改

**共同**

- CDP 永远只绑 127.0.0.1，不对外
- 空闲回收：gateway 侧 30 分钟无连接则 `docker stop`（profile 保留）
- 运行时互斥：同一时刻只跑一个（内存原因），M0 对比时错峰启动

### 4.2 新增：browser-gateway（宿主机小服务）

位置：`/home/ubuntu/repos/Agents-Anywhere/browser-gateway/`（Python，FastAPI/uvicorn，或独立小仓；随 connector 部署）

职责：

1. `POST /open`（只绑 127.0.0.1）：入参 `{sessionId, url?}`；通过 runtime adapter 确保 Steel/Neko 容器运行；若 url 提供则用 CDP 打开；签发一次性 token；返回 `{browserId, liveUrl, cdpUrl, status}`。同一 session 复用同一 browserId。
2. `POST /close`：关闭浏览器网页（容器保留）；会话归档时由 connector 调用。
3. `GET /auth/check`：nginx `auth_request` 子请求，校验 `browser_session` cookie。
4. `POST /auth/exchange`：一次性 token → 设置 HttpOnly/Secure/SameSite=Lax cookie（TTL 12h，绑定 browserId）。
5. `GET /live`：landing 页；从 fragment 读 token，POST 换 cookie，然后 302 到 `/`（Neko 客户端）。
6. 反向代理 `/` 与 `/ws` 到当前运行时的本地端口（Steel 3000 / Neko 8080），HTTP + WebSocket Upgrade。
7. 生命周期：记录 browserId ↔ sessionId；空闲计时；token 消耗与过期清理。

安全：

- 一次性 token：HMAC 签名，含 `browserId`、`exp`、`nonce`；TTL 5 分钟；消费后落内存/Redis 标记
- cookie：HttpOnly、Secure、SameSite=Lax；TTL 12 小时；WS 握手由 nginx `auth_request` 校验
- `open`/`close` 只接受 loopback 调用；CDP 永不对外
- 日志不记录 token、cookie、URL query

### 4.3 connector（AA 与 moonveil 共用；必须可门控）

关键风险：当前 `build_sdk_options` 对 `mcp_servers` 和 `system_prompt.append` 都是**单 control 覆盖式**写法（`connector/runtimes/claude/sdk/client.py:139-148`）。新增第二个 MCP server 前必须先改成合并，否则 change-title 会被覆盖。

改动：

1. 新建 `connector/runtimes/claude/sdk/browser_tool.py`
   - 仿 `title_tool.py:113-207`：`BROWSER_SERVER_NAME="browser"`、`BROWSER_TOOL_NAME="browser_open"`、wire name `mcp__browser__browser_open`
   - 工具描述明确告诉 agent：调用后拿 `cdpUrl`，用 `browserctl`（见 4.3.4）操作；不要另开浏览器
   - handler：HTTP POST `gateway/open`，返回 JSON 文本（SDK 只保证 text content；不要依赖 structuredContent）
   - 工具失败时返回可读错误（容器未就绪 / gateway 不可达），不要静默
2. 修改 `connector/runtimes/claude/sdk/client.py`
   - `new_sdk_client` / `build_sdk_options` 接受 `browser_control`（或改为 `mcp_controls: Sequence`）
   - `:143` 单键赋值改为多 server 合并；`:144-148` system prompt 改为拼接
   - 保持 title 行为逐字节不变（回归测试锁死）
3. 修改 `connector/runtimes/claude/turns/lifecycle.py`
   - 在 `:2428-2435` 旁构建 `browser_control`；`:2437-2448` 传入 `new_sdk_client`
   - 会话停止/归档钩子调用 `gateway/close`（best-effort，失败只记日志）
   - **不要**把 `browser_open` 加进 `messages.py:2944-2954` 的 `is_hidden_tool_name`（否则卡片不出现）
4. 新增 `browserctl`（宿主机 `/home/ubuntu/bin/browserctl`，Node/Playwright）
   - 命令：`open <url>`、`shot <file>`、`eval <js>`、`click <sel>`、`type <sel> <text>`、`tabs`、`state`
   - 通过 `playwright.chromium.connectOverCDP(cdpUrl)` 连同一浏览器；首次使用安装依赖到 `/data`
5. 门控：connector 配置增加 `browser.enabled`（默认 false）与 `browser.gatewayUrl`；moonveil 侧不配置 = 行为零变化
6. 测试：
   - `options.mcp_servers` 同时含 `change-title` 与 `browser`（仿 `tests/test_claude_title_tool.py`）
   - `mcp__browser__browser_open` 投影为 `type="tool"`、`content.kind="mcp"`、`content.server="browser"`、结果 JSON 可解析
   - 门控关闭时 `mcp_servers` 与 system prompt 与今日逐字节一致

### 4.4 iOS

改动点（来自 iOS 调研，行号待实现时复核）：

1. `TimelineEntryPresentation.swift`
   - `:6` `Kind` 增加 `.browser`
   - `.tool` 分支之前（`:85` 附近）判定：`content.server == "browser"` 或 `content.kind == "browser"`
   - 解析：标题（`raw.title/name/description`）、状态（`item.status`）、live URL（`content.result.liveUrl` / `raw.url` / `input.url`）；仅接受 http/https
2. `TimelineRowStructure.swift:26` 之前：browser 行归 `.single`，避免被折进 `.tools` 折叠区导致按钮不可见
3. `SessionTimelineEventView.swift:88-134`：增加 `case .browser`，渲染新卡片；增加 `onOpenBrowser: (URL) -> Void`
4. 新建 `Views/Chat/BrowserTimelineCard.swift`
   - 标题 + 域名 + 状态（运行/失败/已结束）+「打开」按钮
   - 视觉沿用现有卡片语言（参考 `TimelineMarkerRow`、`SessionInteractionCard` 的 glass 卡）；不改现有行高/间距冻结契约
   - 无障碍标签、动态字号、深色模式、本地化键
5. 闭包穿透（现有同款模式）：`SessionTimelineRow.swift:4-15,42` → `SessionTimelineEventView.swift:46-56` → `ChatTimelineView.swift:12-15,536-540,607-609` → `SessionChatView.swift:158-160`
6. `SessionChatView.swift`
   - 新增 `@State private var liveBrowser: LiveBrowserRoute?`
   - `:261-263` 附近加 `.fullScreenCover(item:)`；不要塞进现有 `.sheet(item:)`（sheet 有 detent、可下滑误关）
   - `openBrowser(_:)` 仿 `openFile`
7. 新建 `Views/Browser/LiveBrowserView.swift`
   - `NavigationStack` + 关闭/重载/分享；`WKWebView` 持久化数据存储（不要 `.nonPersistent()`）
   - 导航策略：允许页内 http/https；外链新窗口交系统浏览器
   - 状态：连接中 / 加载中 / 错误 / 离线 / 令牌过期（提示重新打开）
   - WebRTC 不可用时降级：全屏 `SFSafariViewController`
   - 不复制 `WorkspaceFilePreviewSheet` 的 `.id(url)` 重建与 `dismantleUIView` 停载
8. 测试：
   - `SessionPresentationTests` 增加 browser 行的 kind/title/url 断言
   - `TimelineGrouping` 增加 browser 行必须 `.single` 的断言

### 4.5 server

**无改动**：

- `TimelineItemIn.content` 是自由 JSON（`server/agent_server/core/models.py:1067`）
- `type` 枚举保持 5 种（`models.py:58-64`），不新增 `browser` 类型，避免旧 Server 反序列化失败
- `timeline.itemUpsert` 原样落库（`server/agent_server/services/connector_notifications.py:897-907`）
- 不改数据库，无迁移

若后续需要「服务端鉴权签发流 token」，再单独加接口；首版 gateway 自签即可。

---

## 5. 契约与兼容

| 项 | 决定 | 理由 |
|---|---|---|
| timeline 类型 | 不新增，复用 `tool` | 旧 Server 对未知 `type` 会 `ValidationError`；`content` 自由 JSON |
| iOS 识别 | `content.server=="browser"`（兼容 `content.kind=="browser"`） | 不依赖工具名硬编码 |
| 旧客户端 | 显示为普通 MCP 工具行 | 无破坏 |
| 旧 Server | 原样存储 | 无破坏 |
| Web/Android | 首版不改，显示普通工具行 | 非目标 |
| 契约文档 | 不改 wire 契约；补内部设计文档 | AGENTS.md 契约优先 |

---

## 6. 生命周期

- browser 归属：一个 AA session 最多一个 browser，`browserId` 由 gateway 生成并与 `sessionId` 绑定
- 会话归档/删除：connector 调 `gateway/close`；gateway 再空闲回收容器（Bug 库教训：归档必须杀进程，不能留孤儿）
- 容器重启：profile 保留登录态；页面需重新打开（卡片提供「重新打开」，由 agent 再次调用 `browser_open`）
- 令牌过期：landing 页提示；用户重新点卡片（agent 重开）拿新 token
- 并发：同一 browserId 多端只读可接受；首版不限制

---

## 7. 验证计划

### 7.1 自动化

- connector 单测：多 MCP 合并、门控关闭逐字节不变、工具投影字段
- gateway 单测：token 签发/消费/过期/重放、cookie 校验、路径与 browserId 绑定
- iOS 单测：presentation kind/title/url、grouping 为 `.single`
- CI：`ios-build.yml`（swift test）+ connector pytest/ruff（现有 backend CI）

### 7.2 集成

1. `gateway/open` → 容器启动 → CDP 可达 → `browserctl state` 返回页面
2. 一次性 token 换 cookie → 带 cookie 访问 `/` 200 → 无 cookie 401
3. WSS 握手带 cookie 成功；无 cookie 拒绝
4. `gateway/close` → 容器停止 → 无孤儿进程
5. nginx `Upgrade`/`Connection` 头与超时配置（Bug 库：WS 反代缺头会握手失败）

### 7.3 真机验收（pp）

1. 时间线出现卡片，显示域名与状态；不在折叠区
2. 点开全屏，3 秒内出现画面；可点按、滚动、键盘输入中文
3. agent 在服务器上导航/点击，手机画面同步变化
4. 扫码登录一个站点；重启浏览器后登录态仍在
5. 归档会话后容器停止，无残留
6. 回归：change-title 正常、工具行渲染不变、旧卡片无位移

---

## 8. 风险与未决

| 风险 | 影响 | 处置 |
|---|---|---|
| WKWebView 对 Steel live 页 / Neko WebRTC 的兼容性未知 | 卡片点开黑屏 | M0 两者都测；失败降级 SFSafariViewController |
| Steel OSS 的 `userDataDir` 跨会话复用行为未实测 | 登录态不能持久 | M0 必测；不行则改用容器内固定 profile 或切 Neko |
| Steel live 页的 WebSocket 非同源 | gateway 代理要额外改路径 | M0 看 EJS/WS URL；必要时页面注 base 路径 |
| 国内→香港 UDP 质量（Neko） | 画面卡顿 | 先测 Tailscale；必要时 TURN/TCP |
| 内存（Chromium ~1G） | 本机 2.7G 可用，易紧 | 单浏览器 + 空闲回收 + 监控 |
| connector 单 control 覆盖 | title 工具被覆盖（回归） | 先改合并 + 双 server 单测锁死 |
| 会话归档不杀浏览器 | 进程/内存泄漏 | 归档钩子 + 空闲回收 + 验证 |
| 令牌泄漏 | 未授权观看/操作 | 一次性 token + HttpOnly cookie + 短 TTL + 不记日志 |
| Neko 客户端 UI 冗余（聊天/设置） | 卡片内像远程桌面 | 首版接受；后续用配置/遮罩精简 |
| DNS/证书 | 新子域需改 DNS | 需 pp 批准后加 `browser.pipicore.cn` 记录与证书 |

**未决（需要 pp 决定）**：

1. 是否同意新增 DNS 记录 `browser.pipicore.cn`（指向 206，走现有 8443 TLS）；若不改 DNS，退回 Tailscale-only 方案（手机需常开 Tailscale）
2. 是否同意在 206 安装 Neko + browser-gateway（Steel 仅在保底时再装），内存 +~1G

---

## 9. 里程碑与工期

| 里程碑 | 内容 | 预估 |
|---|---|---|
| M0 | Neko 默认（pp 2026-10-23 定）：起容器 + CDP + profile 卷；手机验证画面/接管/中文输入、agent CDP 读页面、登录态持久；Steel 仅在 Neko 不可行时做保底对比 | 0.5–1 天 |
| M1 | gateway + nginx token 鉴权；connector 多 MCP 合并 + browser 工具 + 单测 | 1–1.5 天 |
| M2 | iOS 卡片 + 全屏视图 + 单测 + CI | 1.5–2 天 |
| M3 | 生命周期/安全加固 + 独立审查（L 级）+ 真机验收 | 1 天 |

合计约 4–5.5 个工作日（不含 pp 真机复测等待）。

---

## 10. 发布与回滚

- connector：`browser.enabled` 门控，默认 false；出问题改配置即回滚
- gateway/Neko：独立容器与服务，停容器即回滚；无数据库变更
- iOS：纯增量渲染，旧包不受影响；分支出包，不合 dev
- 服务端：零改动，无需回滚路径

---

## 11. 顺带发现（不在本次范围）

1. connector 的 `mcp_servers` / `system_prompt` 单 control 覆盖写法本身是隐患：未来任何第二个进程内 MCP server 都会踩；建议本次顺手改成 `mcp_controls` 列表（属于本任务必要改动）
2. 卡片实时状态（浏览器已关闭/仍在运行）首版拿不到：需要 gateway → connector → 时间线的状态回推，列为后续
3. Neko 客户端 UI 未做移动端精简，首版可能像远程桌面而非「浏览器卡片」；后续可定制 landing/遮罩
4. 本机内存长期偏紧（swap 50–70%），浏览器常驻会加剧；建议同时评估 sourcekit-lsp 等常驻进程
