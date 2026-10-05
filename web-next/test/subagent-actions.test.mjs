import assert from "node:assert/strict"
import test from "node:test"

import {
  SUBAGENT_LIVE_STATUSES,
  isLiveSubagentTask,
  liveSubagentTasks,
  subagentTaskEntries,
  subagentTaskLabel,
} from "../src/components/session/subagent-actions.ts"

test("only running and async_launched entries stay live", () => {
  const agents = {
    "task-run": { status: "running", subagentType: "general-purpose" },
    "task-async": { status: "async_launched" },
    "task-done": { status: "completed" },
    "task-failed": { status: "failed" },
    "task-stopped": { status: "stopped" },
    "task-killed": { status: "killed" },
    "task-blank": {},
  }
  assert.deepEqual(liveSubagentTasks(agents).map((entry) => entry.taskId), ["task-run", "task-async"])
  assert.deepEqual(SUBAGENT_LIVE_STATUSES, ["running", "async_launched"])
})

test("content without an agents map yields no stop targets", () => {
  // Background bash/workflow cards carry no agents map, so they never render
  // a stop button (pp 10-05: no per-task stop affordance for those types).
  assert.deepEqual(liveSubagentTasks(undefined), [])
  assert.deepEqual(liveSubagentTasks(null), [])
  assert.deepEqual(liveSubagentTasks({ command: "sleep 600", runInBackground: true }), [])
  assert.deepEqual(liveSubagentTasks({ status: "running" }), [])
})

test("malformed agents maps are ignored defensively", () => {
  assert.deepEqual(subagentTaskEntries("running"), [])
  assert.deepEqual(subagentTaskEntries(["running"]), [])
  assert.deepEqual(subagentTaskEntries({ t1: "running" }), [])
  assert.deepEqual(subagentTaskEntries({ "": { status: "running" } }), [])
  assert.deepEqual(subagentTaskEntries({ t1: { status: 3, subagentType: 7 } })[0].status, null)
})

test("entries keep the connector fields and labels fall back meaningfully", () => {
  const [entry] = subagentTaskEntries({
    "task-1": {
      status: "running",
      subagentType: "explore",
      lastToolName: "Bash",
      isBackgrounded: true,
      spawnDepth: 2,
    },
  })
  assert.deepEqual(entry, {
    taskId: "task-1",
    status: "running",
    subagentType: "explore",
    lastToolName: "Bash",
    isBackgrounded: true,
    spawnDepth: 2,
  })
  assert.equal(subagentTaskLabel(entry, "fallback"), "explore")
  assert.equal(isLiveSubagentTask(entry), true)

  const [bare] = subagentTaskEntries({ "task-2": { status: "running" } })
  assert.equal(subagentTaskLabel(bare, "fallback"), "fallback")
  assert.equal(subagentTaskLabel(bare, null), "task-2")
  assert.equal(subagentTaskLabel(bare), "task-2")
})
