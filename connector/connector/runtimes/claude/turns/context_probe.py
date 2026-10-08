"""Ask an idle Claude transport for its own context-window declaration.

The window a client sizes its context ring with comes from the running engine
(`/context`), never from the model name: a gateway serves its own models under
Claude Code's `default` entry, so the catalog's `claude-*` id rules describe a
model that is not running. The transport is the only place the real answer
exists, and it may only be asked between turns.

Serialization, in two layers that already exist:

* the caller takes the session's `execution_lock` — the same lock
  ``start_turn`` registers a turn under — so no turn can start while the probe
  owns the stream, and the probe never runs for a session whose turn is live;
* the probe claims the connection's `current` response through the same
  maintenance-response handshake ``reconcile_tasks`` uses. The reader routes
  every frame it reads to `current`, so the probe's frames land in one queue
  instead of minting a turn (the reader mint branch runs only while `current`
  is None) or being buffered as chrome. ``maintenance`` keeps
  ``select_response`` from spawning a scheduled turn for that response, and
  ``before_tool`` (which locks the connection down for maintenance) is
  irrelevant here because a local command runs no tools.

Nothing on this path projects: the frames are consumed by this function, the
response carries no execution, and the timeline never sees them. A probe that
fails hands the transport back unchanged (its cleanup is the same release
every other response gets); the caller's ledger counts the attempt, and no
turn state is touched either way.
"""

from __future__ import annotations

import asyncio

from connector.logging import logger
from connector.runtimes.claude.domain.context_report import (
    CLAUDE_CONTEXT_PROMPT,
    parse_context_report,
)
from connector.runtimes.claude.sdk.client import query_client
from connector.runtimes.claude.sdk.connection import ClaudeConnection
from connector.runtimes.claude.sdk.events import is_result_message
from connector.runtimes.claude.timeline.messages import message_role, message_text

# The verified local command answers in ~65–300 ms with zero API calls; the
# bound exists only so a wedged CLI can never hold the lock a user's next
# message is waiting for. Reached only between turns, so nothing user-visible
# is delayed by it.
CONTEXT_PROBE_TIMEOUT_SECONDS = 5.0
# Bounded retry policy for a probe that did not produce a window (CLI too old
# to know `/context`, a garbled report, a dropped transport): at most this many
# attempts per model selection, spaced by an exponential backoff.
CONTEXT_PROBE_RETRY_LIMIT = 3
CONTEXT_PROBE_RETRY_BACKOFF_SECONDS = 5.0


async def probe_context_window(
    connection: ClaudeConnection,
    *,
    session_id: str = "",
    prompt: str = CLAUDE_CONTEXT_PROMPT,
    timeout_seconds: float = CONTEXT_PROBE_TIMEOUT_SECONDS,
) -> tuple[str | None, int | None, int | None] | None:
    """Dispatch `/context` and read its report; None when no report arrived.

    Caller contract: the transport is live and quiescent (`current`/`pending`
    clear, no background work) and the caller owns the session's
    `execution_lock`, so no turn can be registered for the duration.
    """

    if (
        connection.closing
        or connection.current is not None
        or connection.pending is not None
    ):
        return None
    response = connection.response_for(None)
    response.maintenance = True
    # No await inside `select_response` for a maintenance response, so the
    # claim is atomic against the reader: the first probe frame cannot arrive
    # before `current` points at this response.
    await connection.select_response(response)
    report_text: str | None = None
    streamed_text: str | None = None
    try:
        async with asyncio.timeout(timeout_seconds):
            await query_client(connection.client, prompt)
            async for message in response.receive_response():
                if is_result_message(message):
                    # The result envelope repeats the report verbatim; it is
                    # the authoritative copy (the assistant frame is the
                    # rendering).
                    result_text = message_text(message)
                    if isinstance(result_text, str) and result_text:
                        report_text = result_text
                    break
                if streamed_text is None and message_role(message) == "assistant":
                    # The assistant frame is the fallback when the envelope
                    # carries no text. User frames (the CLI's `<command-name>`
                    # echo) are never the report.
                    candidate = message_text(message)
                    if isinstance(candidate, str) and candidate:
                        streamed_text = candidate
    except TimeoutError:
        logger.warning(
            "Claude context probe timed out session_id={} timeout_s={}",
            session_id,
            timeout_seconds,
        )
    finally:
        terminal_seen = response.terminal_received
        response.release(interrupted=not terminal_seen)
        if not terminal_seen:
            # No terminal: the response is abandoned rather than left as
            # `current`. A response whose consumer is gone would route every
            # later frame — a user turn's own echo included — into a queue
            # nobody reads, which is the one shape that could hang the
            # session (human turns have no watchdog). The transport itself is
            # left up: what the CLI still owes the probe surfaces at silence,
            # where an unowned result is absorbed and the report's text is
            # local-command chrome.
            connection.drop_current(response)
    text = report_text or streamed_text
    if not text:
        return None
    report = parse_context_report(text)
    if report == (None, None, None):
        # Text came back but nothing in it is the report (a CLI too old to
        # know `/context` answers it as an ordinary prompt): not a calibration,
        # and the attempt ledger counts it as the failure it is.
        return None
    return report
