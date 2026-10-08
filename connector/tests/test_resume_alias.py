"""Resume-alias lineage normalization — connector live fold (P0-3, 2026-10-08).

Why this file exists
--------------------
When a background subagent is resumed through ``SendMessage``, the CLI keys the
resumed task's later lifecycle frames — and the terminal notification — on the
*SendMessage* tool_use id, not on the original Agent dispatch. The live fold
(``ClaudeMessageProjector.fold_agent_task_event``) minted a second Agent card
for that id, and the original dispatch card never received the terminal state:
two cards of the same name, one stranded ``running``, one ``completed``
(``.local-dev/subagent-status-truth-tasks.md`` §2 R4; the two real cases are
``a11bd2c081f4d5efe`` and ``a86b886d8be25726e`` in 88a21126).

The history rebuild already normalizes this (``sessions/reader.py``
``_agent_task_notification_folds``'s ``send_aliases``); this file pins the same
lineage on the live path. The projector learns the join from the frames it
already projects — the Agent receipt's ``agentId`` and the SendMessage call's
``input.to`` — and routes an alias-keyed fold onto the task's single original
dispatch card. Ambiguity or a missing root falls back to the id it came with,
exactly as before.

The wire frames below are trimmed copies of the real 88a21126 transcript shapes
(long bodies elided, shape untouched), so the lineage is the real one.
"""

from __future__ import annotations

from typing import Any

from claude_agent_sdk._internal.message_parser import parse_message

from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sdk.tasks import task_event_from_message
from connector.runtimes.claude.timeline.agent_calls import (
    agent_task_overlay_for_event,
    resolve_resume_alias,
)
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    message_tool_blocks,
    stable_tool_item_id,
)

SESSION = "88a21126-cdd9-41de-9b2e-9726f69aebc7"
# The real pair from 88a21126: the dispatch card (7ee16e2a…, stranded running)
# and the SendMessage-keyed second card (027023ff…, completed).
DISPATCH = "call_01_f1bOyj1v8yXq6VHtV7Lu0884"
SEND = "call_00_h0ilBl1OCk1aY9IAzTRq4284"
TASK = "a11bd2c081f4d5efe"
# A second dispatch root that can be made to claim the same task id, for the
# ambiguity case.
OTHER_DISPATCH = "call_00_OtherDispatchRoot00001"
OTHER_TASK = "b22ce3d192f6"  # 15 chars, the task-id shape


def _parse(frame: dict[str, Any]) -> Any:
    message = parse_message(frame)
    assert message is not None
    return message


def _session() -> ClaudeSession:
    return ClaudeSession(session_id="resume-alias", external_session_id=SESSION)


def _dispatch(tool_use_id: str, description: str = "Add unknown-window ring state") -> dict:
    return {
        "type": "assistant",
        "message": {
            "id": f"dispatch-{tool_use_id}",
            "model": "deepseek-v4.1-flash",
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": tool_use_id,
                    "name": "Agent",
                    "input": {
                        "description": description,
                        "prompt": "You are working in the git worktree ... (elided)",
                        "subagent_type": "general-purpose",
                    },
                }
            ],
        },
        "parent_tool_use_id": None,
        "session_id": SESSION,
        "uuid": f"dispatch-uuid-{tool_use_id}",
    }


def _receipt(tool_use_id: str, task_id: str) -> dict:
    return {
        "type": "user",
        "message": {
            "role": "user",
            "content": [
                {
                    "tool_use_id": tool_use_id,
                    "type": "tool_result",
                    "content": [
                        {
                            "type": "text",
                            "text": (
                                "Async agent launched successfully. (This tool "
                                "result is internal metadata ...) (elided)"
                            ),
                        }
                    ],
                }
            ],
        },
        "parent_tool_use_id": None,
        "session_id": SESSION,
        "uuid": f"receipt-uuid-{tool_use_id}",
        "tool_use_result": {
            "isAsync": True,
            "status": "async_launched",
            "agentId": task_id,
            "description": "Add unknown-window ring state",
            "resolvedModel": "deepseek-v4.1-flash",
        },
    }


def _send_message(tool_use_id: str, target: str) -> dict:
    return {
        "type": "assistant",
        "message": {
            "id": f"send-{tool_use_id}",
            "model": "deepseek-v4.1-flash",
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": tool_use_id,
                    "name": "SendMessage",
                    "input": {
                        "to": target,
                        "recipient": target,
                        "type": "message",
                        "summary": "Resume iOS unknown-window ring state work",
                        "message": "You stopped mid-reconnaissance with no ... (elided)",
                        "content": "You stopped mid-reconnaissance with no ... (elided)",
                    },
                }
            ],
        },
        "parent_tool_use_id": None,
        "session_id": SESSION,
        "uuid": f"send-uuid-{tool_use_id}",
    }


def _task_started(tool_use_id: str, task_id: str) -> dict:
    return {
        "type": "system",
        "subtype": "task_started",
        "task_id": task_id,
        "tool_use_id": tool_use_id,
        "description": "Add unknown-window ring state",
        "subagent_type": "general-purpose",
        "is_backgrounded": True,
        "spawn_depth": 1,
        "task_type": "local_agent",
        "prompt": "You are working in the git worktree ... (elided)",
        "uuid": f"started-uuid-{tool_use_id}",
        "session_id": SESSION,
    }


def _task_notification(tool_use_id: str, task_id: str, summary: str) -> dict:
    return {
        "type": "system",
        "subtype": "task_notification",
        "task_id": task_id,
        "tool_use_id": tool_use_id,
        "status": "completed",
        "output_file": f"/tmp/claude-1001/.../tasks/{task_id}.output",
        "summary": summary,
        "usage": {"total_tokens": 33823, "tool_uses": 7, "duration_ms": 27571},
        "uuid": f"notif-uuid-{tool_use_id}",
        "session_id": SESSION,
    }


def _projector() -> tuple[ClaudeMessageProjector, ClaudeSession]:
    return ClaudeMessageProjector(), _session()


def _agent_card_ids(projector: ClaudeMessageProjector) -> set[str]:
    """Every id the projector minted an Agent card under."""

    return set(projector._agent_cards)


def _fold(projector: ClaudeMessageProjector, session: ClaudeSession, frame: dict, tool_use_id: str):
    event = task_event_from_message(_parse(frame))
    assert event is not None
    overlay, status = agent_task_overlay_for_event(event)
    return projector.fold_agent_task_event(
        session, tool_use_id=tool_use_id, overlay=overlay, status=status
    )


# --------------------------------------------------------------------------
# 1. a resumed task folds onto the original dispatch card (single card)
# --------------------------------------------------------------------------


def test_sendmessage_resume_folds_onto_the_dispatch_card() -> None:
    """The R4 fix: a SendMessage-keyed fold lands on the dispatch card."""

    projector, session = _projector()
    canonical_id = stable_tool_item_id(session, DISPATCH)

    # The dispatch and its async launch receipt — where the task id is learned.
    projector.tool_items_for_message(
        session=session, turn_id="turn-1", message=_parse(_dispatch(DISPATCH))
    )
    projector.tool_items_for_message(
        session=session, turn_id="turn-1", message=_parse(_receipt(DISPATCH, TASK))
    )
    # The SendMessage that resumes the task (a visible tool call as before).
    projector.tool_items_for_message(
        session=session, turn_id="turn-2", message=_parse(_send_message(SEND, TASK))
    )

    # The resumed task's frames are keyed on the SendMessage id (the CLI does
    # exactly this) — but they must land on the one canonical dispatch card.
    started = _fold(projector, session, _task_started(SEND, TASK), SEND)
    assert started.id == canonical_id
    assert started.status == "running"

    notification = _fold(
        projector,
        session,
        _task_notification(SEND, TASK, "RING STATE DONE"),
        SEND,
    )
    assert notification.id == canonical_id
    assert notification.status == "done"
    assert notification.content["summary"] == "RING STATE DONE"

    # One Agent card, and it is the canonical one — no SendMessage-keyed twin.
    assert _agent_card_ids(projector) == {canonical_id}
    assert stable_tool_item_id(session, SEND) not in _agent_card_ids(projector)


def test_sendmessage_receipt_learns_the_alias_before_frames() -> None:
    """The join is learned from the frames the projector already sees."""

    projector, session = _projector()
    canonical_id = stable_tool_item_id(session, DISPATCH)
    for message in (
        _dispatch(DISPATCH),
        _receipt(DISPATCH, TASK),
        _send_message(SEND, TASK),
    ):
        projector.tool_items_for_message(
            session=session, turn_id="turn-1", message=_parse(message)
        )
    # Both maps are exactly the two real ids: the receipt taught task→root, the
    # SendMessage call taught send→task.
    assert projector._task_roots.get(TASK) == {DISPATCH}
    assert projector._send_to_task.get(SEND) == TASK
    assert resolve_resume_alias(
        SEND, send_to_task=projector._send_to_task, task_roots=projector._task_roots
    ) == DISPATCH
    assert canonical_id == stable_tool_item_id(session, DISPATCH)


# --------------------------------------------------------------------------
# 2. ambiguous lineage falls back to the incoming id (today's behavior)
# --------------------------------------------------------------------------


def test_ambiguous_roots_fall_back_to_the_incoming_id() -> None:
    """Two dispatch roots claiming one task must not pick a favourite."""

    projector, session = _projector()
    # Two dispatches both report the same task id (the ambiguity).
    projector.tool_items_for_message(
        session=session, turn_id="turn-1", message=_parse(_dispatch(DISPATCH))
    )
    projector.tool_items_for_message(
        session=session, turn_id="turn-1", message=_parse(_receipt(DISPATCH, TASK))
    )
    projector.tool_items_for_message(
        session=session, turn_id="turn-1", message=_parse(_dispatch(OTHER_DISPATCH))
    )
    projector.tool_items_for_message(
        session=session, turn_id="turn-1", message=_parse(_receipt(OTHER_DISPATCH, TASK))
    )
    projector.tool_items_for_message(
        session=session, turn_id="turn-2", message=_parse(_send_message(SEND, TASK))
    )
    assert projector._task_roots[TASK] == {DISPATCH, OTHER_DISPATCH}

    started = _fold(projector, session, _task_started(SEND, TASK), SEND)
    # Fail-closed: the alias is not resolvable, so it keys its own card exactly
    # as before the fix.
    assert started.id == stable_tool_item_id(session, SEND)
    assert (
        resolve_resume_alias(
            SEND,
            send_to_task=projector._send_to_task,
            task_roots=projector._task_roots,
        )
        is None
    )


# --------------------------------------------------------------------------
# 3. an unresolvable alias stays on its own key (fail-closed)
# --------------------------------------------------------------------------


def test_unresolvable_alias_stays_on_its_own_key() -> None:
    projector, session = _projector()
    # A SendMessage for a task whose dispatch we never saw: mapped, but no root.
    projector.tool_items_for_message(
        session=session, turn_id="turn-2", message=_parse(_send_message(SEND, TASK))
    )
    assert projector._send_to_task.get(SEND) == TASK
    assert projector._task_roots.get(TASK) is None

    started = _fold(projector, session, _task_started(SEND, TASK), SEND)
    assert started.id == stable_tool_item_id(session, SEND)

    # An id that is not a SendMessage alias at all is a pure pass-through.
    assert (
        resolve_resume_alias(
            DISPATCH,
            send_to_task=projector._send_to_task,
            task_roots=projector._task_roots,
        )
        is None
    )


# --------------------------------------------------------------------------
# 4. the canonical card keeps its dispatch content through the resume
# --------------------------------------------------------------------------


def test_canonical_card_keeps_dispatch_content_and_merges_summary() -> None:
    projector, session = _projector()
    canonical_id = stable_tool_item_id(session, DISPATCH)
    dispatched = projector.tool_items_for_message(
        session=session, turn_id="turn-1", message=_parse(_dispatch(DISPATCH))
    )[0]
    projector.tool_items_for_message(
        session=session, turn_id="turn-1", message=_parse(_receipt(DISPATCH, TASK))
    )
    projector.tool_items_for_message(
        session=session, turn_id="turn-2", message=_parse(_send_message(SEND, TASK))
    )

    _fold(projector, session, _task_started(SEND, TASK), SEND)
    final = _fold(projector, session, _task_notification(SEND, TASK, "DONE"), SEND)

    assert final.id == dispatched.id == canonical_id
    # The dispatch prompt/toolUseId survive; the resume's own fields never
    # overwrite the call's (the same merge semantics as a non-resumed card).
    assert final.content["prompt"] == _dispatch(DISPATCH)["message"]["content"][0][
        "input"
    ]["prompt"]
    assert final.content["toolUseId"] == DISPATCH
    assert final.content["agentId"] == TASK
    # The terminal notification's summary and usage are carried through.
    assert final.content["summary"] == "DONE"
    assert final.content["usage"] == {
        "durationMs": 27571,
        "tokens": 33823,
        "toolCalls": 7,
    }
    assert final.content["agents"][TASK]["status"] == "completed"
    assert final.status == "done"


# --------------------------------------------------------------------------
# 5. SendMessage's own visibility is unchanged (lineage only, no card moves)
# --------------------------------------------------------------------------


def test_send_message_row_is_still_projected_as_before() -> None:
    """Recording the alias mints nothing and hides nothing."""

    projector, session = _projector()
    before = len(projector._agent_cards)
    items = projector.tool_items_for_message(
        session=session, turn_id="turn-2", message=_parse(_send_message(SEND, TASK))
    )
    assert len(items) == 1
    # Still a plain tool row under its own id — not an Agent card.
    assert items[0].id == stable_tool_item_id(session, SEND)
    assert items[0].content["kind"] == "tool_call"
    assert len(projector._agent_cards) == before
    # The lineage was recorded as a side effect of that same projection.
    assert projector._send_to_task == {SEND: TASK}


def test_record_send_message_learns_from_block_input_to() -> None:
    """The alias is learned from the raw block's ``input.to``, nothing else.

    The recording runs before visibility is decided, so a SendMessage that a
    future hidden-tool list drops from the rows would still join the lineage
    and redirect its task's frames — without becoming visible itself.
    """

    projector, _ = _projector()
    send_block = message_tool_blocks(_parse(_send_message(SEND, TASK)))[0]
    assert send_block.tool_name == "SendMessage"
    assert send_block.tool_input["to"] == TASK
    projector._record_send_message(send_block)
    assert projector._send_to_task == {SEND: TASK}
    # Nothing is published by the recording alone.
    assert projector._agent_cards == {}
    # A non-SendMessage block records nothing.
    agent_block = message_tool_blocks(_parse(_dispatch(DISPATCH)))[0]
    projector._record_send_message(agent_block)
    assert projector._send_to_task == {SEND: TASK}


# --------------------------------------------------------------------------
# 6. the resolver itself, pinned directly
# --------------------------------------------------------------------------


def test_resolve_resume_alias_edges() -> None:
    roots = {TASK: {DISPATCH}}
    sends = {SEND: TASK}
    assert resolve_resume_alias(SEND, send_to_task=sends, task_roots=roots) == DISPATCH
    # Not an alias at all.
    assert resolve_resume_alias(DISPATCH, send_to_task=sends, task_roots=roots) is None
    # Alias with no root seen.
    assert (
        resolve_resume_alias(SEND, send_to_task=sends, task_roots={}) is None
    )
    # Ambiguous roots.
    assert (
        resolve_resume_alias(
            SEND, send_to_task=sends, task_roots={TASK: {DISPATCH, OTHER_DISPATCH}}
        )
        is None
    )
    # A self-referential mapping never loops back on itself.
    assert (
        resolve_resume_alias(
            SEND, send_to_task={SEND: TASK}, task_roots={TASK: {SEND}}
        )
        is None
    )
    # An unrelated task id under OTHER_TASK resolves independently.
    assert (
        resolve_resume_alias(
            "call_00_x",
            send_to_task={"call_00_x": OTHER_TASK},
            task_roots={OTHER_TASK: {OTHER_DISPATCH}},
        )
        == OTHER_DISPATCH
    )
