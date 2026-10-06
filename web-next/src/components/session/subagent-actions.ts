/**
 * Pure helpers for the per-subagent stop affordance (A3 batch, task spec v2 §7).
 *
 * The connector folds per-task state into an agent_call card as
 * `content.agents` (`taskId -> {status, subagentType, isBackgrounded,
 * spawnDepth, lastToolName}`). Live-ness is decided locally from the entry
 * status only — never from the session runtimeStatus: a background subagent
 * keeps running while the session itself sits idle, so an interrupt-style
 * runtimeStatus gate would hide the button exactly when it is needed.
 */

/** Entry statuses that still mean the subagent is alive (§7.3). */
export const SUBAGENT_LIVE_STATUSES: readonly string[] = ["running", "async_launched"]

/**
 * How long a stop button stays disabled while waiting for the terminal task
 * event before it re-enables so the user can retry (§7.3 timeout cleanup).
 */
export const SUBAGENT_STOP_PENDING_TIMEOUT_MS = 10_000

export type SubagentTaskEntry = {
  taskId: string
  status: string | null
  subagentType: string | null
  lastToolName: string | null
  isBackgrounded: boolean | null
  spawnDepth: number | null
}

function asText(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

/** Parse the connector's `content.agents` map defensively; the key is the taskId. */
export function subagentTaskEntries(agents: unknown): SubagentTaskEntry[] {
  const map = asRecord(agents)
  if (!map) return []
  const entries: SubagentTaskEntry[] = []
  for (const [rawTaskId, value] of Object.entries(map)) {
    const taskId = rawTaskId.trim()
    if (!taskId) continue
    const raw = asRecord(value)
    if (!raw) continue
    entries.push({
      taskId,
      status: asText(raw.status),
      subagentType: asText(raw.subagentType),
      lastToolName: asText(raw.lastToolName),
      isBackgrounded: typeof raw.isBackgrounded === "boolean" ? raw.isBackgrounded : null,
      spawnDepth: typeof raw.spawnDepth === "number" ? raw.spawnDepth : null,
    })
  }
  return entries
}

export function isLiveSubagentTask(entry: SubagentTaskEntry): boolean {
  return entry.status !== null && SUBAGENT_LIVE_STATUSES.includes(entry.status)
}

/** The entries a stop button may target; every button binds exactly one taskId. */
export function liveSubagentTasks(agents: unknown): SubagentTaskEntry[] {
  return subagentTaskEntries(agents).filter(isLiveSubagentTask)
}

/** Row label for a per-task stop row; the taskId is the last-resort identity. */
export function subagentTaskLabel(entry: SubagentTaskEntry, fallbackAgentType?: string | null): string {
  return entry.subagentType ?? asText(fallbackAgentType) ?? entry.taskId
}
