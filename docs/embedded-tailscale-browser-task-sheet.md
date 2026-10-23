# 任务单：AA 内置 Tailscale + 内置浏览器（生产级）

- 日期：2026-10-23
- 级别：L（App 内新增网络栈 + 新浏览器 + 设置体系 + 构建/CI 变更）
- 分支：`feat/ios-in-app-browser`（基于 `origin/dev` `9ad2abe1`；不合 dev，分支出包）
- 状态：**方案待 pp 确认，未开始实现**
- 旧文档：`docs/in-app-browser-task-sheet.md`（SFSafariViewController 方案）已过时，本文档取代

---

## 1. 问题与背景

pp 的目标：**AA 自带 Tailscale**。用户在 AA 设置里连接后即可使用；聊天里的内网链接能直接在 AA 内置浏览器打开预览；**不依赖官方 Tailscale App，也不依赖小火箭（Shadowrocket）**。

约束：

- 产品级、面向大量用户，禁止盲目改动
- 不能影响用户已开启的任何 VPN
- 时间线远程浏览器是另一条押后的线，不在本次范围

## 2. 目标与非目标

### 目标

1. App 内嵌 userspace Tailscale（TailscaleKit），设置页可配置、连接、查看状态与组网设备
2. 聊天中的 http(s) 链接在 AA 内置浏览器打开；内网链接走 App 内 Tailscale，公网链接走正常网络
3. 不创建系统 VPN、不申请 Network Extension、不改路由表；与任何已有 VPN 共存
4. 内网 HTTP 页面可打开（ATS 例外只放开 Web 内容）
5. 失败语义明确：未连接 Tailscale 时内网链接给出可操作提示，绝不静默走公网/系统 VPN

### 非目标（本期）

- 系统级 VPN（NE / Packet Tunnel）
- 地址栏输入、多标签、书签、历史、下载管理
- 自定义网段 / subnet routes 配置（二期）
- 「设为 AA 服务器地址」等与服务器配置耦合的功能（二期）
- 时间线远程浏览器（押后线）
- Android / Web 端

## 3. 已验证事实与未知点

### 已验证（有证据）

- **TailscaleKit 存在且是用户态**：`tailscale/libtailscale` 的 Swift 包，提供 `TailscaleNode`（authKey/网页登录、hostName、controlURL、ephemeral）、`loopback()`（返回 SOCKS5 的 ip/port/凭据）、`statusJSON()`（`ipnstate.Status`：Self/Peer）、`URLSessionConfiguration.proxyVia(node)`；`make ios` 产出 iOS framework；示例 entitlements 仅需 network client/server，**无 NE 权限**
- **WKWebsiteDataStore 支持多持久 store 与代理**：`+dataStoreForIdentifier:`（iOS 17+）、`proxyConfigurations`（`nw_proxy_config_t`，iOS 17+）——WebKit 头文件确认
- **ATS 现状**：`ios/Agents Anywhere/Info.plist` 已有 `NSAllowsLocalNetworking` 与 10/8、127/8、169.254/16 例外，**没有** 100.64/10、fd7a::/48、也没有 `NSAllowsArbitraryLoadsInWebContent`
- **设置根**：`ios/Agents Anywhere/Agents Anywhere/Views/Settings/AccountSettingsSheet.swift:53` 已是 NavigationLink 模式，可挂新页
- **现有 WKWebView**：仅 `WorkspaceFilePreviewSheet.swift:135`，用 `.nonPersistent()`，不共享 default store
- **CI**：`.github/workflows/ios-build.yml` 的 build job 条件为 `github.ref == 'refs/heads/dev'`，feature 分支的 workflow_dispatch 只跑 test
- **真机实测**（2026-10-23，tailnet-only HTTP 页面）：Claude App（SFSafariViewController）可打开；Grok / ChatGPT 不行（强制 HTTPS / ATS）

### 未知点（阶段 0 spike 必须验证）

1. TailscaleKit framework 接入现有单 target Xcode 工程的具体形态与构建耗时
2. `WKWebsiteDataStore.proxyConfigurations` 是否接受 TailscaleKit 的 SOCKS5 端点与凭据（Swift 类型需编译确认）
3. MagicDNS 主机名能否经该代理解析；若不能，是否改用 Peer IP
4. HTTP + `NSAllowsArbitraryLoadsInWebContent` 是否放行；WebSocket 经代理是否可用
5. 与系统 VPN（小火箭全量代理 / 官方 Tailscale / 都不开）三种场景的共存
6. 后台挂起/恢复后的重连行为、auth key 过期/吊销错误路径

## 4. 总体架构

```
AA Settings
  └─ TailscaleSettingsView
       └─ TailscaleManager (actor, App 级)
            └─ TailscaleNode (userspace, 无 NE)
                 ├─ loopback SOCKS5 (127.0.0.1:随机端口, tsnet 凭据)
                 └─ statusJSON() → Self/Peer 设备列表

Chat link (http/https)
  └─ ChatLinkRouter
       ├─ aa-workspace-file → 内部文件预览（不变）
       ├─ http/https → InAppBrowserView (WKWebView)
       │     ├─ tailnet host → 内网 WKWebsiteDataStore(forIdentifier:) + proxyConfigurations
       │     └─ 其他 host → WKWebsiteDataStore.default()（系统网络，尊重用户自己的 VPN）
       ├─ mailto → 系统
       └─ 其他 scheme → 丢弃

Tailscale 未连接 + 内网 host → 明确错误页 + 去设置；绝不静默直连
```

## 5. 关键设计决策

| 决策 | 选择 | 理由 |
|---|---|---|
| 网络实现 | TailscaleKit userspace | 无 NE、无系统 VPN、不影响已有 VPN；sideload 无需 NE 权限 |
| 浏览器引擎 | WKWebView（自绘 chrome） | SFSafariViewController 无法使用 App 内代理 |
| 内网隔离 | `WKWebsiteDataStore(forIdentifier:)` 固定 UUID + 代理 | 多个持久 store 共存，内网 Cookie 与公网隔离；重装/重启后保留 |
| 公网流量 | default store | 尊重系统网络与用户已有 VPN，不走内置节点 |
| ATS | 只加 `NSAllowsArbitraryLoadsInWebContent` | 放开 Web 内容 HTTP，原生请求 ATS 不变 |
| 内网判定 | 100.64/10、fd7a:115c:a1e0::/48、`*.ts.net` | 首版覆盖；自定义网段二期 |
| 失败语义 | 明确失败 + 引导 | 静默直连会泄漏/误判，禁止 |
| 配置存储 | auth key → Keychain；其余 → UserDefaults | 密钥不进普通存储、不进日志 |
| 发布 | feature flag 默认关闭，设置入口标 Beta | 先小范围验证，再默认开启 |

## 6. 模块与文件清单

### 6.1 新增（App target）

- `/home/ubuntu/repos/AA-wt-in-app-browser/ios/Agents Anywhere/Agents Anywhere/Services/Tailscale/TailscaleManager.swift`
  - actor/ObservableObject；持有 `TailscaleNode`
  - 状态机：`.disabled / .notConfigured / .starting / .connected(nodeName, ip) / .reconnecting / .error(kind)`
  - `start/stop/restart/statusJSON/loopbackConfig`
  - 前后台恢复；错误映射；退避重试
- `.../Services/Tailscale/TailscaleSettingsStore.swift`
  - Keychain 读写 auth key；UserDefaults 读写 enabled/hostName/controlURL
  - 只暴露是否已配置与末 4 位，不提供明文读取
- `.../Services/Tailscale/TailnetHostMatcher.swift`
  - 纯逻辑：URL host → tailnet / public / local
- `.../Services/Tailscale/TailnetDataStoreFactory.swift`
  - 固定 UUID 的 `WKWebsiteDataStore(forIdentifier:)`
  - 由 `node.loopback()` 构造 `ProxyConfiguration(socksv5Proxy:)` 并设置凭据
  - 缓存 store 实例；节点重启后刷新代理配置
- `.../Models/Tailscale/TailscaleStatus.swift`
  - 解码 statusJSON 所需字段（Self/Peer）
- `.../Views/Settings/TailscaleSettingsView.swift`
  - 开关、auth key、hostname、controlURL、状态、设备列表、测试连接、清除配置
- `.../Views/Browser/InAppBrowserView.swift`
  - WKWebView 容器 + 自绘 chrome（关闭/后退/前进/刷新/分享/地址显示/进度）
  - 加载/错误/离线/未连接内网 状态
- `.../Views/Browser/InAppBrowserWebView.swift`
  - UIViewRepresentable；按 host 选 data store；导航策略；target=_blank 同页处理
- `.../Models/Chat/ChatLinkRouter.swift`
  - 文件引用 → 内部预览；http/https → 浏览器；mailto → 系统；其他 → 丢弃

### 6.2 修改

- `.../Views/Chat/SessionChatView.swift`
  - `SessionSheet` 增加 `.browser(URL)` 与 id
  - `sheetContent` 增加 case（保持独立方法，避免类型检查超时）
  - `OpenURLAction` 改为 `ChatLinkRouter`
  - 浏览器用 `.fullScreenCover(item:)` 呈现（自绘 chrome 自带关闭）
- `.../Views/Settings/AccountSettingsSheet.swift`
  - 增加 `NavigationLink { TailscaleSettingsView() }`
- `/home/ubuntu/repos/AA-wt-in-app-browser/ios/Agents Anywhere/Info.plist`
  - 增加 `NSAllowsArbitraryLoadsInWebContent`
- `.../Agents Anywhere.xcodeproj/project.pbxproj`
  - 增加 TailscaleKit framework 依赖与 Embed（或本地 SwiftPM binaryTarget，见 6.3）
- 本地化资源（xcstrings）
  - 新增设置与浏览器文案（8 语，按现有规范）
- `.github/workflows/ios-build.yml`
  - 增加 TailscaleKit 构建步骤与缓存（若采用 CI 构建方案）

### 6.3 构建方案（阶段 0 拍板）

- 方案 A：脚本 `scripts/build-tailscale-kit.sh` 用 `make ios` 产出 `TailscaleKit.xcframework` 到 `ios/Vendor/`（gitignore），pbxproj 直接引用并 Embed
- 方案 B：本地 SwiftPM 包包装 `.binaryTarget(path:)`，xcodeproj 添加本地 package 依赖
- 共同：CI 在 xcodebuild 前构建 framework，缓存 `libtailscale/swift/build`；Go 工具链由 macOS runner 提供
- 不提交二进制产物；本地首次构建需要 Go + Xcode 16.1+

## 7. 分阶段执行步骤

### 阶段 0：Spike（2–3 天，只验证，不合并 UI）

1. TailscaleKit 接入：按 6.3 产出并链接 framework，App 能编译
2. 起节点：authKey 从代码/环境注入，日志看到 tailnet IP
3. URLSession 经 `proxyVia(node)` 访问 `100.x` 服务，确认 200
4. WKWebView + `dataStoreForIdentifier` + `proxyConfigurations` 打开 tailnet HTTP 页（加 ATS key），确认渲染与 JS
5. MagicDNS 名字、WebSocket、后台恢复逐项记录
6. 三种 VPN 场景共存测试
7. 输出《Spike 报告》：每项 通过/失败/替代方案

**Gate**：任一核心项失败，暂停并汇报，不进入阶段 1。

### 阶段 1：设置与节点（3–4 天）

1. `TailscaleSettingsStore` + Keychain
2. `TailscaleManager` 状态机与生命周期
3. `TailscaleSettingsView`：配置/连接/状态/错误/清除
4. 设备列表（statusJSON，Self + Peer，在线/离线/最后在线）
5. 纯逻辑单测（状态转移、host 判定、错误映射）

### 阶段 2：内置浏览器（3–5 天）

1. `ChatLinkRouter` + 单测
2. `SessionSheet.browser` + `fullScreenCover`
3. `InAppBrowserView` chrome 与状态
4. 内网/公网 data store 分流
5. 未连接内网地址的引导页（跳设置）
6. 本地化、无障碍、深色模式
7. 聊天时间线回归（布局无位移）

### 阶段 3：回归、审查与出包（2–3 天）

1. 真机矩阵（见第 8 节）
2. 回归：文件预览、Artifact、设置页、聊天布局
3. 独立审查（L 级，按工程准则 §6）
4. 记录包体增量、冷启动耗时
5. feature flag 默认关闭 → 内测 → 按 pp 决定是否默认开启
6. 分支出包（CI 条件需确认，见第 11 节）

## 8. 测试方案

### 8.1 自动化

- `ChatLinkRouter`：文件引用 / http / https / mailto / 非法 scheme / 大写 scheme
- `TailnetHostMatcher`：100.63.x、100.64.0.0、100.127.255.255、100.128.x、fd7a::/48、`*.ts.net`、公网 IP、localhost、10/8、192.168/16
- 状态机纯策略：未配置→连接中→已连接→断开；错误 key/断网/过期
- CI：`swift test --package-path ios` 全绿；framework 构建步骤从零/缓存两种耗时记录

### 8.2 真机矩阵

| 场景 | 预期 |
|---|---|
| 设置粘贴有效 auth key → 连接 | 显示节点名与 tailnet IP；设备列表出现本机+Peer |
| 无效/过期 key | 明确错误 + 重试/更换入口 |
| 断开网络 | 状态转错误，恢复后自动重连（或一键重连） |
| 聊天内网 HTTP 链接 | AA 内置浏览器打开，JS 执行、页内跳转正常 |
| 聊天内网 HTTPS 链接 | 正常打开（证书有效时） |
| Tailscale 关闭时点内网链接 | 明确「需要内网连接」+ 去设置，不静默直连 |
| 聊天公网链接 | 默认 store 打开，行为与现状一致 |
| 开小火箭全量代理 | AA 内网仍可访问；小火箭内其他 App 不受影响 |
| 开官方 Tailscale | AA 正常；两套节点不冲突 |
| 两者都关 | AA 内网仍可访问（内置的核心价值） |
| 切后台 5 分钟回来 | 内网页面可重载，节点自动恢复 |
| 杀 App 重开 | 配置与内网 Cookie 保留 |
| 文件引用链接 | 仍打开内部文件预览 |
| mailto | 仍走系统邮件 |

### 8.3 回归

- 现有 `WorkspaceFilePreviewSheet`（`.nonPersistent()`）不受 ATS web-content 例外影响？需实测（例外只放宽，不改变隔离）
- 聊天时间线行布局无位移；现有 sheet 路由正常
- 设置页其他入口正常；无新增崩溃
- 包体增量与冷启动耗时记录在验收报告

## 9. 回归风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| TailscaleKit 构建复杂/CI 变慢 | 出包失败或超时 | 阶段 0 先做构建 spike；缓存 framework；记录从零/缓存耗时 |
| WKWebsiteDataStore 代理 API 行为不符预期 | 内网页面打不开 | 阶段 0 验证；备选：内网仅 URLSession / 或改用 HTTPS-only |
| MagicDNS 经代理解析失败 | 域名链接失败 | 用 statusJSON 取 Peer IP 改写；或提示用 IP |
| ATS 例外影响其他 WKWebView | 安全面变大/预览行为变化 | 只开 web-content 级；回归文件预览与 Artifact |
| 内网 store Cookie 与公网隔离不当 | 串 Cookie/隐私 | 固定独立 data store identifier；不在公网 store 加载内网 URL |
| 系统 VPN 共存冲突 | 用户网络异常 | userspace 无路由变更；三场景真机验证 |
| 后台挂起导致节点失效 | 回前台首次打开失败 | 前台恢复重连 + 重载；明确状态 |
| auth key 泄漏 | 安全风险 | Keychain + 不落日志 + 密文输入 |
| 包体/启动开销 | 用户体验下降 | 记录增量；必要时懒加载 framework 资源 |
| 分支构建流程 | 无法出测试包 | 先确认现有 gate 流程；不在本任务里擅自改 CI 条件 |

## 10. 安全与隐私

- auth key：Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），不进 UserDefaults、日志、崩溃上报
- 节点状态：Application Support；不备份到 iCloud（按需设置 `isExcludedFromBackup`）
- 代理仅 127.0.0.1；凭据由 TailscaleKit loopback 提供；不对外监听
- 日志只记状态转移与错误码，不记 URL 查询串、Cookie、key
- 内网 data store 独立 identifier，隔离 Cookie
- 未连接时内网目标显式失败，禁止静默直连

## 11. 构建与 CI

- 需要 Go（libtailscale 构建）+ Xcode 16.1+；CI runner 为 macos-26
- 新增构建步骤：`make -C <libtailscale>/swift ios`（或等价），产物放 `ios/Vendor/`
- 缓存 key：libtailscale commit + Xcode 版本
- **未决**：`ios-build.yml` 的 build job 目前只在 `dev` 跑；feature 分支只跑 test。分支出包需按现有 gate 流程确认（或临时分支改条件），不在本任务里擅自改
- 本地开发需要安装 Go；文档补充「首次构建」说明

## 12. 发布与回滚

- Feature flag：`aa.tailscale.enabled`（默认关闭），设置入口显示 Beta
- 回滚：关闭 flag 即回到现有行为；framework 与代码保留不影响旧功能
- 无服务端改动、无数据库迁移
- 分支出包，未合 dev

## 13. 未决问题（需 pp 拍板）

1. **auth key vs 网页登录**：首版建议 auth key（简单、可控）；网页登录二期
2. **内网浏览范围**：是否也要把公网链接统一走 WKWebView 自绘浏览器（建议是，体验一致；公网仍走 default store）
3. **自定义网段 / subnet routes**：首版只支持 100.64/10 + fd7a::/48 + *.ts.net；自定义放二期？
4. **分支出包流程**：确认现有 gate 方式后再改 CI
5. **设备列表动作**：首版只读（复制 IP）；「设为 AA 服务器地址」二期？

## 14. 验收标准

1. 用户只装 AA：设置里粘贴 auth key → 连接成功，显示节点名/IP/设备列表
2. 聊天里的内网 HTTP/HTTPS 链接在 AA 内置浏览器打开，JS/页内跳转正常
3. 公网链接行为与现状一致（可正常打开）
4. 手机开启小火箭/官方 Tailscale 时，AA 内网访问仍正常，其他 App 不受影响
5. 两者都不开时，AA 内网访问仍正常
6. Tailscale 关闭时点内网链接：明确提示，不静默直连
7. 文件引用、mailto、现有设置页、聊天布局零回归
8. CI 全绿；包体与启动耗时增量在报告中记录
9. L 级独立审查通过

## 15. 工期

| 阶段 | 内容 | 预估 |
|---|---|---|
| 0 | Spike（构建/节点/代理/ATS/MagicDNS/共存） | 2–3 天 |
| 1 | 设置 + 节点 + 设备列表 + 单测 | 3–4 天 |
| 2 | 内置浏览器 + 路由 + 分流 + 文案 | 3–5 天 |
| 3 | 回归 + 审查 + 出包 | 2–3 天 |

合计约 **2–3 周**（不含 pp 真机等待与 CI 排期）。
