"""The compact command supported by AA's native Claude runtime."""

from connector.runtime_protocol import RuntimeCommand

IDLE = ("idle", "error")


def list_claude_commands(
    external_session_id: str | None,
    query: str | None = None,
    limit: int = 50,
    *,
    status: str = "idle",
) -> tuple[RuntimeCommand, ...]:
    """Describe the commands a Claude session exposes right now.

    ``/compact`` is the only command on offer: the CLI reports far more native
    commands, but AA deliberately exposes a single one so the client UI stays
    identical across runtimes. Availability is decided here rather than by the
    runtime so the catalog always explains *why* a command is greyed out.
    """

    reason = None
    if not external_session_id:
        reason = "session_unloaded"
    elif status not in IDLE:
        reason = f"session_{status}"
    command = RuntimeCommand(
        id="compact",
        title="Compact",
        description="Compact the session context.",
        enabled=reason is None,
        disabled_reason=reason,
        # Compaction runs on the whole conversation, so there is nothing for the
        # user to fill in; an appended argument is rejected on execution.
        accepts_args=False,
        metadata={
            "ui": {
                "kind": "execute",
                "allowedStatuses": list(IDLE),
                "acceptsMultiline": False,
            }
        },
    )
    needle = (query or "").strip().casefold()
    return tuple(
        c
        for c in (command,)
        if not needle
        or needle
        in " ".join((c.id, c.title, c.description or "", *c.aliases)).casefold()
    )[: max(0, min(limit, 1000))]
