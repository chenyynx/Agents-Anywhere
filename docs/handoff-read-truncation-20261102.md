# 交接单 — Read/工具结果截断（数据级）与全文件加载

> 日期：2026-11-02（CST）· 分支：`fix/timeline-deferred-read` · worktree：`/home/ubuntu/aa-wt-attachments`
> 本单只描述当前真实状态；未验证的会标「未验证」。

## 0. 一句话

官方「已截断」是**工具结果本身**的截断（`ToolResult.isTruncated`），不是 AA 的 deferred 客户端窗口。现在 connector 已把 Read 的官方截断字段写进 tool row，iOS 实时卡片在底部显示「已截断」，并可从同一行「加载完整文件」经 connector `fs/readText` 拉全文。CI 864（`3ade20d9`）在跑；连接器/服务端部署待执行。

## 1. 关键结论（避免再走弯路）

- **官方截断 = 数据级**：`ClaudeModels.ToolResult.isTruncated`（swiftdump 19238）；卡片内 `0d8e.tool_truncated` = "Truncated" / "已截断"（`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/strings-diff.csv:3548`）。实时流也带这个字段，所以官方 live 也截断。
- **AA 原来的「已截断」接错了**：它接在 `content.deferred`（deferred 窗口）上。deferred 只表示「这行没加载完整」，不代表工具输出被截断；两者已拆开。
- **客户端 live 路径走 runtime events**（`GET /sessions/{id}/events`），不是 v2 timeline/snapshot。杀 App 不清本地缓存/游标，重开时事件流会把完整行补回来；客户端又有「完整行不被摘要覆盖」的保护。因此**不要再用「杀 App + 大输出」去触发 deferred UI**——那条路走不通。
- **Read 的截断标志在 transcript**：`toolUseResult.file = { numLines, startLine, totalLines, truncatedByTokenCap }`。实测 3000 行文件：`1769 / 1 / 3000 / true`（transcript tool_use id `call_00_t5TuM9DzhUa8z1FJz99R6132`，session jsonl `/home/ubuntu/.claude/projects/-home-ubuntu/1c062bb2-d0f4-434c-973a-90d6d22ecfd7.jsonl`）。connector 之前把这整块丢了。
- **UI 位置/字体**：pp 的官方参考是卡片内左下、13 pt、深灰（截图量得 ~sRGB 0.31 / #4F4D4A），左 16 pt、上下 12 pt；加载动作也必须在**卡片底部**，用现成的「格式化」（Prettify）文字 face（mono 13 / secondary），不要胶囊、不要放头部。

## 2. 已完成（worktree，已推）

分支 `fix/timeline-deferred-read`，**代码 head `3ade20d9`**（本 docs 提交在其后，分支 head 会多一个 `docs(ios)` commit）。

| commit | 内容 |
|---|---|
| `867ee8c4` | **connector**：`connector/connector/runtimes/claude/timeline/messages.py` 新增 `_read_file_metadata` / `_tool_result_is_truncated`，把 `content.readMetadata` + `content.truncated` 写进 tool row；测试 `connector/tests/test_claude_read_truncation.py`（3 passed）。 |
| `66c29688` | **iOS 模型/视图**：`Models/Chat/Code/CodeToolOutput.swift` 新增 `CodeReadMetadata` / `CodeToolTruncation`；Read/文本/Diff 卡片在数据级截断时显示 `ToolTruncatedNote`；`DeferredLoadFooter` 不再把 deferred 叫「已截断」；测试 `ios/Tests/ClientCoreTests/CodeToolTruncationTests.swift`。 |
| `4fc29449` | **iOS 全文件加载**：`SessionChatModel.readFullFile`（connector `/fs/readText`）+ Read 卡片状态/部分/失败；`Localizable.xcstrings` 新增「已加载前 %@；文件超出此大小」。 |
| `3ade20d9` | **位置修正**：加载动作从头部移到卡片底部，与状态同一行，使用 Prettify 文字 face（无胶囊）；deferred 行的加载动作也在底部 footer。 |

CI（workflow `ios-build.yml`，branch dispatch）：
- run **862** `66c29688`：test / timeline-autorun / code-profile / build 全绿。
- run **863** `4fc29449`：全绿（但按钮在头部，已被 864 取代）。
- run **864** `3ade20d9`：**交接时在跑**，查：`gh run list --branch fix/timeline-deferred-read` 或 GitHub Actions run id `41323938109`。绿了出 **b864**。

## 3. 部署仓（`/home/ubuntu/repos/moonveil-cloud`，分支 `moonveil`）

**本地已提交、未 push：**

| commit | 内容 |
|---|---|
| `c3ea9b86` | connector 同上（`connector/.../messages.py` + tests）。运行中的 connector 是 **editable 安装**：`/home/ubuntu/repos/moonveil-cloud/connector/.venv`，systemd `moonveil-connector.service`，ExecStart `.../.venv/bin/anywhere-cli start --config /home/ubuntu/.agents-anywhere-moonveil/connector.json`。**重启服务才加载新代码**。 |
| `f66df2c2` | server deferred stub：`server/agent_server/infra/timeline_store.py` 把 `truncated`/`readMetadata` 加入 `_STUB_REQUIRED_KEYS`，`STUB_VERSION` 升 **2**；测试 `server/tests/test_deferred_stub_truncation.py`。 |

- connector 测试（两仓均 3 passed）：
  - worktree：`cd /home/ubuntu/aa-wt-attachments/connector && /home/ubuntu/.local/bin/uv run pytest tests/test_claude_read_truncation.py -q`
  - 部署仓：`cd /home/ubuntu/repos/moonveil-cloud/connector && .venv/bin/python -m pytest tests/test_claude_read_truncation.py -q`
- server stub **纯函数已内联验证**：stub 269 bytes（≤2048），`truncated`/`readMetadata` 保留，`output`/filler 被丢弃。正式 pytest 需要 `AGENT_SERVER_TEST_DB_URL`（一次性 PostgreSQL），本机未跑全量。
- **未部署**：server 镜像 `moonveil-cloud-server:latest`（容器 `moonveil-cloud-server-1`）未重建/重启；`STUB_VERSION=2` 只在源码里。deferred 快照路径要生效必须重建 server（compose `/home/ubuntu/moonveil-deploy/docker-compose.moonveil.yml`）——**生产共享服务，重启前先问 pp**。

## 4. 验收（真机，必须按顺序）

1. 装 **b864**（CI run 864 绿后的包）。
2. 重启连接器（**会断当前会话**，正常）：
   ```bash
   sudo systemctl restart moonveil-connector
   ```
3. 新开一个会话，让它 Read 一个超过工具输出上限的文件：
   - 现成文件：`/tmp/trunc-lines-3000.txt`（2999 行 / ~153 KB；Read 截到 1769 行，`truncatedByTokenCap=true`）。
   - 若临时文件没了：`python3 -c "open('/tmp/trunc-lines-3000.txt','w').write('\n'.join('LINE-%04d '%i+'x'*40 for i in range(3000)))"`。
4. 打开该 Read 卡片，**底部一行**应看到：
   - 「已截断」（13 pt 深灰，左 16 / 上下 12）；
   - 右侧「加载完整文件」（mono 13 / secondary，无胶囊）；
   - 点它 → 卡片正文替换为全文，同一位置变「已加载完整文件」；若服务端 fs 读取被截到 4 MiB，显示「已加载前 %@；文件超出此大小」；失败显示「无法加载完整文件。」+「重试」。

若第 4 步没出现：
- 确认 connector 确实重启（`systemctl is-active moonveil-connector` + 进程启动时间）。
- 确认 App 是 b864。
- 检查新会话的 Read 行 content 是否含 `readMetadata`/`truncated`（服务端 DB 或 connector 日志）。注意：live runtime 路径与 deferred/timeline 路径不同，不要再去杀 App 触发 deferred。

## 5. 已知边界 / 下一步

1. **加载完整文件用的是 connector 的 `/fs/readText`**，不是官方 runtime 的 `SessionStore.readFile` 控制。路径为 `readMetadata.filePath`（绝对路径；server `_resolve_posix_workspace_path` 对绝对路径原样返回），root = `session.metadata.cwd`。**未验证**：connector `fs.readText` 对 workspace 外/受限路径的行为；虚拟文件/运行期文件可能读不到。真实工作区文件应可用。
2. **deferred 快照路径**：server stub 的 `STUB_VERSION` 升 2 后，旧 v1 stub 会被 deferred reader 忽略（回退完整行），直到行再次 upsert 生成 v2 stub。connector 重启 + `syncExistingOnConnect` 是否会重写旧行，**未验证**。
3. **Read 官方长脚注**（`显示 N 行（已在工具输出上限处截断）`）现在用统一的短「已截断」；`readMetadata.numLines/totalLines` 已在客户端，若 pp 要官方长脚注可直接渲染。
4. **死代码（Q 级）**：动作移到卡片底部后，`CodeToolCardAction` / `headerAction` / `codeToolHeaderAction` 在 Code 卡片里已无人传值；可清理。`DeferredLoadFooter` 的 footer 按钮仍是 footnote/tint 文字（不是 Prettify face），是否统一待定。
5. **gate 覆盖**：`code-profile` 不跑全文件加载（无网络）；`CodeToolTruncationTests` 只覆盖标志解析。全文件加载的真机路径按第 4 步验。
6. **服务端部署**：见 §3；需要 pp 点头后重建/重启 server。

## 6. 证据位置

- 官方字符串：`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/strings-diff.csv:3548`（`tool_truncated` = Truncated / 已截断）。
- 官方截断模型：`ClaudeModels.ToolResult.isTruncated`（swiftdump 19238；sbx 的 `/home/ubuntu/v261023/ipsw-swiftdump-new.txt`）。
- 官方卡片内视图：`0x102a4a92c`（Text + foregroundStyle + full-width frame + 12 pt padding）；颜色/字号以 pp 2026-11-01 截图为据（13 pt、~#4F4D4A）。
- Read transcript 字段：session `1c062bb2-d0f4-434c-973a-90d6d22ecfd7` 的 tool_use `call_00_t5TuM9DzhUa8z1FJz99R6132`；`1769 / 1 / 3000 / true`。
- 部署服务：`moonveil-connector.service`（editable 源 `/home/ubuntu/repos/moonveil-cloud/connector`）；server 容器 `moonveil-cloud-server-1`；compose `/home/ubuntu/moonveil-deploy/docker-compose.moonveil.yml`。
- 触发文件：`/tmp/trunc-lines-3000.txt`（2999 行，Read 会截断）。

## 7. 恢复提示词（新会话直接粘贴）

```
继续 AA iOS 的 Read 工具截断线。worktree /home/ubuntu/aa-wt-attachments，分支
fix/timeline-deferred-read（代码 head 3ade20d9，docs 提交在其后，已推）。先读
docs/handoff-read-truncation-20261102.md，再按第 5 节边界核对现状。

数据级截断（ToolResult.isTruncated）已端到端接好：connector 867ee8c4 写
content.readMetadata/truncated；iOS 66c29688/4fc29449/3ade20d9 在卡片底部显示
「已截断」+「加载完整文件」（Prettify face，无胶囊）。CI 864（3ade20d9）在跑，
先确认它绿、取 b864。

部署仓 /home/ubuntu/repos/moonveil-cloud（分支 moonveil）本地有 c3ea9b86（connector）
与 f66df2c2（server stub，STUB_VERSION=2），都未 push/未部署。连接器是
moonveil-connector.service 的 editable 安装，重启才生效；server 未重建。

下一步：装 b864 → sudo systemctl restart moonveil-connector（会断当前会话）→
新会议读 /tmp/trunc-lines-3000.txt → 验底部「已截断」+「加载完整文件」→ 点后
「已加载完整文件」。之后再做 server 重建（需 pp 点头）和 §5 的边界项。
不要再用「杀 App + 大输出」触发 deferred；live 走 runtime events。
```

## 8. 约束（同工程准则）

- 不 force push；不合并主线/beta，合并先问 pp。
- 重启 `moonveil-connector` 会终止当前会话；重启生产 server 属共享状态操作，先问 pp。
- 密钥/令牌/用户内容不进日志、代码、commit；数据与产物在 `/data`，根盘 ≥15%。
- 文件路径对 pp 一律给完整绝对路径 + 单反引号。
