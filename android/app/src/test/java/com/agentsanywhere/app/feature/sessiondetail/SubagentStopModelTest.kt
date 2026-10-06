package com.agentsanywhere.app.feature.sessiondetail

import com.agentsanywhere.app.api.RemoteTimelineItem
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SubagentStopModelTest {
    private fun agentCallItem(
        agents: JSONObject,
        cardStatus: String = "running",
        revision: Int = 1,
        updatedSeq: Int = 1,
    ) = RemoteTimelineItem(
        id = "item-1",
        sessionId = "session-1",
        type = "tool",
        status = cardStatus,
        role = null,
        text = "",
        content = JSONObject()
            .put("kind", "agent_call")
            .put("action", "invoke")
            .put("description", "Dispatch subagent")
            .put("agents", agents),
        source = JSONObject(),
        orderSeq = 1,
        revision = revision,
        updatedSeq = updatedSeq,
        createdAt = "",
        updatedAt = null,
    )

    private fun project(
        incoming: List<RemoteTimelineItem>,
        current: TimelineProjection = TimelineProjection(emptyList(), emptyList()),
    ): TimelineProjection = mergeRemoteTimelineItems(
        currentOrdering = current.orderingItems,
        currentMessages = current.messages,
        incoming = incoming,
        replace = false,
    )

    private fun agentCall(projection: TimelineProjection): TimelineAgentCall {
        val message = projection.messages.single()
        assertEquals(TimelineMessageKind.AgentCall, message.kind)
        return message.agentCall!!
    }

    @Test
    fun projectionCarriesEachTaskWithItsIdAndState() {
        val agents = JSONObject()
            .put(
                "task-1",
                JSONObject()
                    .put("status", "running")
                    .put("subagentType", "general-purpose")
                    .put("isBackgrounded", true)
                    .put("spawnDepth", 1)
                    .put("lastToolName", "Bash"),
            )
            .put("task-2", JSONObject().put("status", "completed"))

        val call = agentCall(project(listOf(agentCallItem(agents = agents))))

        // The JVM json artifact does not guarantee key order; compare as a set.
        assertEquals(
            setOf("task-1", "task-2"),
            call.tasks.map { it.taskId }.toSet(),
        )
        val first = call.tasks.first { it.taskId == "task-1" }
        assertEquals("running", first.status)
        assertEquals("general-purpose", first.subagentType)
        assertTrue(first.isBackgrounded)
        assertEquals("Bash", first.lastToolName)
        // Only the running task is a stop target; the closed one is not.
        assertEquals(listOf("task-1"), call.stoppableTasks().map { it.taskId })
    }

    @Test
    fun tasksWithoutTaskIdOrWithUnknownShapesAreNotStopTargets() {
        val agents = JSONObject()
            .put("", JSONObject().put("status", "running")) // A blank key is never a task id.
            .put("task-1", JSONObject()) // A status-less task event leaves {} behind.
            .put("task-2", "not-an-object")
            .put("task-3", JSONObject().put("status", "running"))

        val call = agentCall(project(listOf(agentCallItem(agents = agents))))

        assertEquals(listOf("task-3"), call.tasks.map { it.taskId })
        assertEquals(listOf("task-3"), call.stoppableTasks().map { it.taskId })
    }

    @Test
    fun liveStatusesMatchTheConnectorSet() {
        assertTrue(agentTaskIsLive("running"))
        assertTrue(agentTaskIsLive("async_launched"))
        listOf("completed", "failed", "stopped", "killed", "").forEach { status ->
            assertFalse(status, agentTaskIsLive(status))
        }
    }

    @Test
    fun stopTargetsRequireBothTheCapabilityAndALiveTask() {
        val call = TimelineAgentCall(
            action = TimelineAgentCallAction.Invoke,
            tasks = listOf(
                TimelineAgentTask(taskId = "task-1", status = "running"),
                TimelineAgentTask(taskId = "task-2", status = "completed"),
                TimelineAgentTask(taskId = "task-3", status = "async_launched"),
            ),
        )

        assertEquals(
            listOf("task-1", "task-3"),
            subagentStopTasks(canControlSubagents = true, call = call).map { it.taskId },
        )
        assertTrue(subagentStopTasks(canControlSubagents = false, call = call).isEmpty())
        assertTrue(subagentStopTasks(canControlSubagents = true, call = null).isEmpty())
    }

    @Test
    fun terminalTaskEventClosesTheStopTarget() {
        val running = project(
            incoming = listOf(
                agentCallItem(
                    agents = JSONObject().put("task-1", JSONObject().put("status", "running")),
                    revision = 1,
                    updatedSeq = 1,
                ),
            ),
        )
        assertEquals(listOf("task-1"), agentCall(running).stoppableTasks().map { it.taskId })

        val converged = project(
            incoming = listOf(
                agentCallItem(
                    agents = JSONObject().put("task-1", JSONObject().put("status", "stopped")),
                    cardStatus = "interrupted",
                    revision = 2,
                    updatedSeq = 2,
                ),
            ),
            current = running,
        )

        assertTrue(agentCall(converged).stoppableTasks().isEmpty())
    }

    @Test
    fun capabilityGateNeedsAllThreeStates() {
        fun usable(supported: Boolean, available: Boolean, allowed: Boolean): Boolean =
            EffectiveCapabilities(
                capabilities = listOf(
                    EffectiveCapability(
                        capabilityId = SESSION_SUBAGENT_CONTROL_CAPABILITY,
                        version = "1",
                        scope = "session",
                        runtime = "claude",
                        sessionId = "session-1",
                        supported = supported,
                        available = available,
                        allowed = allowed,
                        unavailableReason = null,
                        parameters = emptyMap(),
                    ),
                ),
                isLoaded = true,
            ).isUsable(SESSION_SUBAGENT_CONTROL_CAPABILITY)

        assertTrue(usable(supported = true, available = true, allowed = true))
        assertFalse(usable(supported = false, available = true, allowed = true))
        assertFalse(usable(supported = true, available = false, allowed = true))
        assertFalse(usable(supported = true, available = true, allowed = false))
        assertFalse(EffectiveCapabilities(isLoaded = true).isUsable(SESSION_SUBAGENT_CONTROL_CAPABILITY))
    }
}
