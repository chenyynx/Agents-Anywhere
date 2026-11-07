# 交接：流式增量刷新（2026-11-08）

> 读我：`docs/perf-streaming-incremental-task-sheet.md`（P1–P5 计划与验收线）+ 本文（现状、坑、数据）。
> 分支 `feat/device-main-thread-sampler`，head `0279793f`。worktree：`/home/ubuntu/aa-wt-sampler`。

## 1. 这条分支这两天做了什么

`a1` 正文块去掉 `UITextView`：`AssistantMarkdownBlockTextView` 改为 `UIView` + 自持 TextKit 2 栈、自绘 line fragment（`Views/Chat/TextKit/AssistantMarkdownTextLayout.swift`）。
`a2` 选中/复制：`UITextInteraction(.nonEditable)` + 自实现 `UITextInput`；分词器 `SelectableMarkdownTextTokenizer`（句/段按 `\n`、行取 layout fragment，官方粒度）；复制写 `public.html` + `public.utf-8-plain-text`；复制后取消选中；点空白取消选中；选中期间临时放开祖先 `clipsToBounds`（否则行首手柄被切）。
`a3` 链接色：`NSTextLayoutManagerDelegate.renderingAttributesForLink` 返回正文色 + 单下划线（字符串上的颜色会被渲染层覆盖）。
`a4` 性能：`stepGroupSignature` 复用 `group.summary`（refresh 22.2 → 16.7 ms）；抽屉转场、拖动/惯性期间挂起 `apply` 与整次 `reloadFromContent`（滑动 hitch 129 → 16，coast 60 → 9）。

## 2. 已经踩过的坑（改代码前必读）

1. **`NSTextContentStorage.textStorage` 懒创建**。取不到时**不能**返回临时对象，否则写入丢失、下次按下标插入直接 SIGABRT（b1034 闪退）。init 里先赋一个空串物化。
2. **绘制守卫不能用懒对象**。曾用 `ownStorage.textStorage?.length` 做 `draw()` 守卫 → 恒 0 → 整屏文字不画（b1038）。现在用 `ownStorage.documentRange` 偏移长度。
3. **选中高亮不要自己画**。`UITextInteraction` 会按 `selectionRects(for:)` 自己画；再画一层 = 透明度翻倍，看起来是黑块。
4. **`NativeChatTests` 三条契约**（`ios/Tests/ClientCoreTests/NativeChatTests.swift:60-78`）：renderer-owned 行必须**立即**发布、`nextBatchAt` 不变。曾试图加 0.1 s 节拍，测试红。要提频必须放在 UI 层，不能改 publish 语义。
5. **滑动挂起只允许 `historyPaging` 例外**。曾用"item 数不变"做判据，被流式尾部的行集变化绕过，apply 在拖动中照跑。
6. **程序化写 offset 会吞 `scrollViewDidEndDecelerating`**（本仓库 `:2583-2591` 的注释）。挂起必须配 100 ms 重检定时器，不能只靠回调。
7. CI：`ios-build.yml` 的 push 过滤不含本分支，**推送不会自动构建**，必须手动 dispatch（见 §4）。

## 3. 探针数据基线（真机 iPhone15,2 / iOS 26.2）

| 版本 | refresh avg | apply avg / max | frame hitches | coast hitches | 备注 |
| --- | --- | --- | --- | --- | --- |
| b1045 基线 | 22.2 ms | 20 / 534 ms | 63 | 51 | summary 未复用 |
| b1046 | 16.7 ms | 19 / 475 ms | 99 | 74 | 抽屉挂起 |
| b1051 | 16.8 ms | 22 / 547 ms | 129 | 74 | 滚动挂起（判据错） |
| b1053 | 18.0 ms | 21 / 101 ms | **16** | **9** | 判据改 `historyPaging` + refresh 挂起 |

对照实验（不流式滑 15 s）：hitch 6 次、coast 5/232 ≈ 2%。

结论：**稳态流式的主要成本是每次 flush 的 refresh 18 ms + apply 21 ms**（470 项里通常只变 1 项），与滑动无关；这正是 P1/P2 要解决的。

## 4. 出包与取证

```bash
cd /home/ubuntu/aa-wt-sampler
git push origin feat/device-main-thread-sampler
TOKEN=$(git remote get-url origin | sed -n 's#.*x-access-token:\([^@]*\)@.*#\1#p')
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/chenyynx/Agents-Anywhere/actions/workflows/ios-build.yml/dispatches" \
  -d '{"ref":"feat/device-main-thread-sampler","inputs":{"title":"<改动>","build":"true","probe":"true"}}'
```
探针包下载：`https://github.com/chenyynx/Agents-Anywhere/releases/tag/ipa-feat-device-main-thread-sampler`。

真机：会话「···」→ 诊断浮窗 → 清空 → 复现 → 打点 → 导出 txt。
要看的行：`adapter.refresh` / `adapter.group` / `adapter.signature` 的 n、avg、max；`applies` / `applyMsMax` / `measureMsMax`；`scrollHitchesCoast/Drag`；`FINDINGS` 里的 `rekey_churn`。

## 5. 下一步

按任务单 P1 → P2（同一批，一个包）→ P3 + P4（一批）→ P5 单独。
硬约束：不改 publish 契约、不动历史分页锚点计算、每阶段配单测（P2 必须做「全量 vs 增量」对拍）、真机验过再进下一批。

---

## 6. 待修 bug：中断后用户气泡停在「发送中」（2026-11-08 真机）

**症状**：点中断后，刚发出的用户消息气泡仍是待发样式（灰底 + 转圈），不回到普通气泡，也不出现重试/消失。

**代码定位**
- 气泡渲染：`TimelineChatContentAdapter.swift:1233` `.pending(id)` → `PendingMessageRow`，样式由 `V2PendingMessage.delivery` 决定。
- 待发记录只在「非 `.sending`」时才允许被移除：`V2SessionModel.swift:644`（`dismissPendingMessage` 的过滤条件）。
- 回声看门狗只处理 `delivery == .accepted` 的情况（`V2SessionModel.swift:629`）。
- 中断入口：`SessionChatModel.interrupt()`（`SessionChatModel.swift:757`），成功后不改 pending 状态。

**推断根因**：发送后 pending 停在 `.sending`（服务端回执/回声未到），用户随即中断；中断只结束回合，不会推进该 pending 的 delivery，于是它既不能被 dismiss（`.sending` 被过滤），也等不到 accepted 的看门狗 → 永久转圈。

**修法方向（未实施，需先确认 Delivery 状态机）**
1. 中断成功后，对 `delivery == .sending` 的 pending 做一次权威确认（复用 `loadLatest(authoritative: true)`）；确认存在则移除 pending（真实行已在时间线里），不存在则置为失败态给重试。
2. 或者放宽 `dismissPendingMessage`：`.sending` 在回合结束后也允许移除（需要同时保证不会重发同内容时被 `unresolvedPending` 误挡——`blocksRepeatSend` 的判断要跟着改）。

**风险**：这条链路直接关系「消息是否真的发出去了」，改错会导致重复发送或消息丢失；必须配单测（pending 状态机：sending → accepted → 移除；sending → 中断 → 失败/移除）。
