package com.agentsanywhere.app.feature.sessiondetail

data class SessionTimelineState(
    val messages: List<TimelineMessage> = emptyList(),
    val orderingItems: List<TimelineOrderingItem> = emptyList(),
    val nextSeq: Int = 0,
    val hasMore: Boolean = false,
    val eventCursor: String = "seq:0",
    val isLoading: Boolean = false,
    val loadingOlder: Boolean = false,
    val errorMessage: String? = null,
    val historyErrorMessage: String? = null,
)

/**
 * Server-owned ordering data kept separately from visible Android rows.
 * Every source item is ordered by the same v2 Timeline contract as Web.
 */
data class TimelineOrderingItem(
    val id: String,
    val orderSeq: Int,
    val revision: Int,
    val updatedSeq: Int,
)

data class TimelineMessage(
    val id: String,
    val sourceItemId: String = id,
    val author: MessageAuthor,
    val text: String,
    val attachments: List<TimelineAttachment> = emptyList(),
    val status: String = "done",
    val type: String = "message",
    val kind: TimelineMessageKind = TimelineMessageKind.Text,
    val title: String = "",
    val subtitle: String = "",
    val badge: String = "",
    val detail: String = "",
    val body: String = "",
    val contentKind: String = "",
    val reasoningSegments: List<String> = emptyList(),
    val command: String = "",
    val output: String = "",
    val input: String = "",
    val toolError: String = "",
    val fileChanges: List<TimelineFileChange> = emptyList(),
    val agentCall: TimelineAgentCall? = null,
    val rawContent: String = "",
    val orderSeq: Int = 0,
    val revision: Int = 1,
    val updatedSeq: Int = 0,
    val clientMessageId: String? = null,
    val contentHash: String = "",
    val sourceRuntime: String? = null,
    val sourceItemType: String? = null,
    val sourceReplacedBy: String? = null,
    val optimistic: Boolean = false,
    val errorMessage: String? = null,
)

data class TimelineFileChange(
    val action: String,
    val path: String,
    val diff: String,
)

data class TimelineAgentCall(
    val action: TimelineAgentCallAction,
    val description: String = "",
    val parentItemId: String? = null,
    val tasks: List<TimelineAgentTask> = emptyList(),
)

/**
 * One entry of a card's `agents` map: the CLI's per-task state for a
 * dispatched subagent, keyed by `taskId` (the same id `stop_task` takes).
 */
data class TimelineAgentTask(
    val taskId: String,
    val status: String,
    val subagentType: String = "",
    val isBackgrounded: Boolean = false,
    val lastToolName: String = "",
)

/**
 * Subagent statuses that still mean the task is alive. Mirrors the
 * connector's `AGENT_TASK_LIVE_STATUSES`: an entry without a recognised
 * status (including a status-less task event) is not stoppable.
 */
internal val AGENT_TASK_LIVE_STATUSES = setOf("running", "async_launched")

internal fun agentTaskIsLive(status: String): Boolean = status in AGENT_TASK_LIVE_STATUSES

/** Tasks on this card that can be stopped individually, in wire order. */
internal fun TimelineAgentCall.stoppableTasks(): List<TimelineAgentTask> =
    tasks.filter { it.taskId.isNotBlank() && agentTaskIsLive(it.status) }

/**
 * The card's stop targets: the capability is the only global gate (the turn
 * status must not be consulted), and the per-task status stays local.
 */
internal fun subagentStopTasks(
    canControlSubagents: Boolean,
    call: TimelineAgentCall?,
): List<TimelineAgentTask> = if (canControlSubagents) call?.stoppableTasks().orEmpty() else emptyList()

enum class TimelineAgentCallAction {
    Invoke,
    Spawn,
    SendInput,
    Resume,
    Wait,
    Close,
    Unknown,
}

data class TimelineAttachment(
    val fileId: String,
    val name: String,
    val mediaType: String,
    val size: Long,
    val sha256: String? = null,
    val localPreviewUri: String? = null,
) {
    val isImage: Boolean
        get() = mediaType.startsWith("image/")
}

data class AttachmentImageRequest(
    val url: String,
    val authorizationToken: String,
    val cacheKey: String,
)

data class DownloadedAttachment(
    val fileId: String,
    val name: String,
    val mediaType: String,
    val size: Long,
    val sha256: String,
    val bytes: ByteArray,
)

enum class MessageAuthor {
    User,
    Agent,
    Tool,
}

enum class TimelineMessageKind {
    Text,
    Reasoning,
    Command,
    FileChange,
    AgentCall,
    ToolCall,
    Artifact,
    Marker,
    Error,
    Diagnostic,
    System,
}
