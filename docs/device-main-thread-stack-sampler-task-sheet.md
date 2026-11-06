# 真机主线程栈采样器任务单（2026-11-06）

> 级别：L（性能线核心流程；探针专属，不进正式包）
> 分支：`feat/device-main-thread-sampler`（从 `feat/drawer-perf-probe` 拉出）
> 关联：`docs/perf-scroll-smoothness-20261105-task-sheet.md`、`memory/aa-backlog.md` 的「2026-11-06 17:30」条目

## 1. 为什么做

10-31 到 11-06 的所有探针都是**计时**探针：在已知回调上打点。结论只能是「卡顿不在这些地方」——11-06 的实测（固定尺寸 + 块尺寸缓存，命中 99%，真排版 4790→114 次）证明 Textual 排版与尺寸协商都不是来源，手感无变化。

要在真机上指出「这 30–80ms 到底花在哪个函数」，只有一条路：**主线程调用栈采样**。

## 2. 方案

新增 `MainThreadStackSampler`（仅 `AA_TIMELINE_PROBE` 编译）：

- 专用后台线程每 2ms 采样主线程：`thread_suspend` → `thread_get_state(ARM_THREAD_STATE64)` → 沿帧指针回溯（`vm_read_overwrite` 安全读栈）→ `thread_resume`
- 采样只发生在滚动期间（`isTracking || isDecelerating`），滚动停止 0.25s 后自动暂停；一次会话最多 60s 活跃采样 / 30k 样本
- 缓冲区全部预分配，采样循环内不做堆分配、不加锁（主线程被挂起时采样线程不取任何锁）
- 滚动结束/导出时聚合相同调用栈，`dladdr` 符号化（Swift 符号走 `swift_demangle`），输出 top 20 栈 + 每次 >33ms 卡顿窗口内的头号栈
- 报告并入现有 `TimelineProbeStore.report()` 的 `--- MAIN THREAD STACKS ---` 段

## 3. 风险与对策

| 风险 | 对策 |
|---|---|
| 挂起主线程造成死锁 | 采样线程在挂起窗口内只调 mach trap + `vm_read_overwrite`，不取锁、不分配、不写日志 |
| 帧指针被优化掉 | arm64 默认保留 x29 帧链；退化时至少保留 pc + lr 两帧 |
| arm64e 指针签名 | 所有栈上取出的地址按 47 位掩码去签名后再 `dladdr` |
| Release 二进制被 strip，符号化为空 | 探针构建传 `STRIP_INSTALLED_PRODUCT=NO`；同时上传 dSYM 作为离线兜底 |
| 采样器自身扰动 | 2ms 一次、深度上限 64；报告带 active/samples/frames 便于判断开销 |

## 4. 验证

- **CI 自测（模拟器）**：Debug + `-DAA_TIMELINE_PROBE` 构建，`aa-stack-sampler-selftest` 启动；主线程跑已知函数 2s，采样器应采到该函数的栈并写出 JSON。断言 `samples >= 100` 且 top 栈含自测函数名。
- **真机**：出探针包（`probe=true`），pp 滚动 20–30s → 导出报告；确认 `MT` 段有栈、卡顿窗口有归属。
- 现有 `scroll-profile` / 单测保持绿。

## 5. 不做

- 不改正式包行为（文件全部 `#if AA_TIMELINE_PROBE`）
- 不做在线聚合/上传（仍是本地报告 + 导出）
- 不覆盖抽屉（抽屉已降到 p50 17ms，先解决滚动）
