import assert from "node:assert/strict"
import test from "node:test"
import { registerSource } from "./helpers/onboarding-source.mjs"

const hook = registerSource()
const { DashboardApi } = await import("../src/features/dashboard/api.ts")
const { CAPABILITY, capabilityIsUsable } = await import("../src/components/session/capabilities.ts")
hook.deregister()

function mockClient(requests, response = { ok: true, result: { stopped: true } }) {
  return {
    post: async (path, body) => {
      requests.push({ path, body })
      return response
    },
  }
}

test("manual interrupt asks the runtime to preserve background work", async () => {
  const requests = []
  const api = new DashboardApi(mockClient(requests, { ok: true, result: {} }))
  await api.interruptSession("token", "s1")
  assert.deepEqual(requests, [
    { path: "/sessions/s1/runtime/interrupt", body: { preserveBackground: true } },
  ])
})

test("stopSubagent posts the frozen endpoint and binds one taskId per request", async () => {
  const requests = []
  const api = new DashboardApi(mockClient(requests))
  const response = await api.stopSubagent("token", "s 1", "task-1")
  assert.deepEqual(requests, [
    { path: "/sessions/s%201/runtime/subagent/stop", body: { taskId: "task-1" } },
  ])
  assert.equal(response.result.stopped, true)
})

test("subagent control capability needs all three usable states", () => {
  assert.equal(CAPABILITY.subagentControl, "session.subagent_control")
  const set = (overrides) => ({
    revision: 1,
    capabilities: [{
      capabilityId: "session.subagent_control",
      runtime: "claude",
      supported: true,
      available: true,
      allowed: true,
      ...overrides,
    }],
  })
  const scope = { runtimeType: "claude" }
  assert.equal(capabilityIsUsable(set({}), CAPABILITY.subagentControl, scope), true)
  assert.equal(capabilityIsUsable(set({ supported: false }), CAPABILITY.subagentControl, scope), false)
  assert.equal(capabilityIsUsable(set({ available: false }), CAPABILITY.subagentControl, scope), false)
  assert.equal(capabilityIsUsable(set({ allowed: false }), CAPABILITY.subagentControl, scope), false)
  assert.equal(capabilityIsUsable(null, CAPABILITY.subagentControl, scope), false)
})
