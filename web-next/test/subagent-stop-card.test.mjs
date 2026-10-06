import assert from "node:assert/strict"
import test from "node:test"
import { readFileSync } from "node:fs"
import { JSDOM } from "jsdom"
import { registerSource } from "./helpers/onboarding-source.mjs"

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "https://app.example.test/", pretendToBeVisual: true })
for (const key of ["window", "document", "navigator", "HTMLElement", "HTMLButtonElement", "Element", "Node", "MutationObserver", "getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame"]) {
  Object.defineProperty(globalThis, key, { configurable: true, value: dom.window[key] })
}
// Route window timers through globalThis so node:test mock timers can drive
// the stop button's fallback timeout.
Object.defineProperty(dom.window, "setTimeout", { configurable: true, value: (...args) => globalThis.setTimeout(...args) })
Object.defineProperty(dom.window, "clearTimeout", { configurable: true, value: (...args) => globalThis.clearTimeout(...args) })
globalThis.ResizeObserver = class { observe() {} disconnect() {} }
globalThis.IS_REACT_ACT_ENVIRONMENT = true

const hook = registerSource()
const { createElement: h, act } = await import("react")
const { createRoot } = await import("react-dom/client")
const { NextIntlClientProvider } = await import("next-intl")
const { ToolCard } = await import("../src/components/session/session-tool-cards.tsx")
const { dashboardApi } = await import("../src/features/dashboard/api.ts")
const { toast } = await import("sonner")
hook.deregister()

const messages = JSON.parse(readFileSync(new URL("../messages/en.json", import.meta.url), "utf8"))

// Collect failure toasts instead of rendering a Toaster.
const errorToasts = []
toast.error = (title, options) => { errorToasts.push(`${title ?? ""}\n${options?.description ?? ""}`) }

const session = { id: "sess_fixture", cwd: "/work" }

function agentCallItem(agents) {
  return {
    id: "item-agent-1",
    sessionId: session.id,
    type: "tool",
    status: "running",
    role: null,
    content: {
      kind: "agent_call",
      action: "invoke",
      description: "Review the diff",
      agentType: "general-purpose",
      agents,
    },
    source: {},
    orderSeq: 1,
    revision: 1,
    contentHash: "hash",
    updatedSeq: 1,
    createdAt: "2026-10-06T00:00:00Z",
    updatedAt: "2026-10-06T00:00:00Z",
  }
}

async function mountCard(t, agents) {
  const host = document.createElement("div")
  document.body.append(host)
  const root = createRoot(host)
  await act(async () => root.render(h(NextIntlClientProvider, { locale: "en", messages, timeZone: "UTC" }, h(ToolCard, {
    item: agentCallItem(agents),
    token: "fixture-token",
    session,
    resolvingNoticeId: null,
    resolvingActionId: null,
    onRespondInteraction: () => {},
    canStopSubagents: true,
  }))))
  t.after(async () => { await act(async () => root.unmount()); host.remove() })
  return host
}

function stopButtons(host) {
  return [...host.querySelectorAll("button")].filter((node) => (node.getAttribute("aria-label") ?? "").startsWith("Interrupt"))
}

async function click(node) {
  assert.equal(node.disabled, false)
  await act(async () => { node.click() })
}

function stubStop(t, result) {
  const calls = []
  t.mock.method(dashboardApi, "stopSubagent", async (...args) => { calls.push(args); return result })
  return calls
}

test("two live subagents render one row and one button per task", async (t) => {
  const calls = stubStop(t, { ok: true, result: { stopped: true } })
  const host = await mountCard(t, {
    t1: { status: "running", subagentType: "explore" },
    t2: { status: "async_launched", subagentType: "plan", lastToolName: "Bash" },
  })
  const buttons = stopButtons(host)
  assert.equal(buttons.length, 2)
  assert.deepEqual(buttons.map((node) => node.getAttribute("aria-label")), [
    "Interrupt: explore",
    "Interrupt: plan · Bash",
  ])
  assert.match(host.textContent, /explore/)
  assert.match(host.textContent, /plan · Bash/)
  await click(buttons[0])
  await click(buttons[1])
  assert.deepEqual(calls, [
    ["fixture-token", "sess_fixture", "t1"],
    ["fixture-token", "sess_fixture", "t2"],
  ])
})

test("a single live subagent gets one row-end button bound to its task", async (t) => {
  const calls = stubStop(t, { ok: true, result: { stopped: true } })
  const host = await mountCard(t, { t1: { status: "running", subagentType: "explore" } })
  const buttons = stopButtons(host)
  assert.equal(buttons.length, 1)
  assert.equal(buttons[0].getAttribute("aria-label"), "Interrupt: explore")
  // Single-entry mode adds no extra row: the label lives on the button only.
  assert.doesNotMatch(host.textContent, /explore/)
  await click(buttons[0])
  assert.deepEqual(calls, [["fixture-token", "sess_fixture", "t1"]])
})

test("an unknown task id stays silent and re-arms the button", async (t) => {
  errorToasts.length = 0
  const calls = stubStop(t, { ok: true, result: { stopped: false } })
  const host = await mountCard(t, { t1: { status: "running", subagentType: "explore" } })
  const button = stopButtons(host)[0]
  await click(button)
  assert.equal(errorToasts.length, 0)
  assert.equal(button.disabled, false)
  await click(button)
  assert.equal(calls.length, 2)
})

test("an error envelope reports the failure and re-arms the button", async (t) => {
  errorToasts.length = 0
  stubStop(t, { ok: false, result: null, error: { code: "conflict", message: "stop rejected" } })
  const host = await mountCard(t, { t1: { status: "running" } })
  const button = stopButtons(host)[0]
  await click(button)
  assert.equal(errorToasts.length, 1)
  assert.match(errorToasts[0], /stop rejected/)
  assert.equal(button.disabled, false)
})

test("a confirmed stop holds the button until the fallback timeout re-arms it", { timeout: 20_000 }, async (t) => {
  stubStop(t, { ok: true, result: { stopped: true } })
  const host = await mountCard(t, { t1: { status: "running", subagentType: "explore" } })
  const button = stopButtons(host)[0]
  t.mock.timers.enable({ apis: ["setTimeout"] })
  await click(button)
  assert.equal(button.disabled, true)
  await act(async () => { t.mock.timers.tick(10_000) })
  assert.equal(button.disabled, false)
})
