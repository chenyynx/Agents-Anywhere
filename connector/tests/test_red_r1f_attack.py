"""R1 round-6 attacks — the c1f repair on `e7b50b47` (R1e-2 parity).

Round 6 verifies the `toolUseResult` branch now judged by
`is_async_agent_receipt`, and attacks the new `_receipt_row_body_text`
extractor against the text the message view hands the same predicate.

Read-only: no product code is modified.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime
from typing import Any

from connector.runtimes.claude.sessions.subagent_oracle import (
    _is_receipt_row,
    _receipt_row_body_text,
    scan_raw_transcript,
)
from connector.runtimes.claude.timeline.agent_calls import is_async_agent_receipt
from connector.runtimes.claude.timeline.messages import _content_text, _result_text

TASK_ID = "a90d5e84970e81d34"
NOW_MS = 1_791_457_800_000
RECEIPT_TEXT = f"Async agent launched successfully.\nagentId: {TASK_ID} (internal ID)"


def _iso(ms: int = NOW_MS) -> str:
    return (
        datetime.fromtimestamp(ms / 1000, tz=UTC)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def _row(
    *,
    content: Any,
    tool_use_result: Any = "ABSENT",
    row_type: str = "user",
) -> dict[str, Any]:
    row: dict[str, Any] = {
        "type": row_type,
        "uuid": "row-1",
        "timestamp": _iso(),
        "message": {"role": "user", "content": content},
    }
    if tool_use_result != "ABSENT":
        row["toolUseResult"] = tool_use_result
    return row


def _tool_result_block(inner: Any, *, tool_use_id: str = "call_1") -> dict[str, Any]:
    return {"type": "tool_result", "tool_use_id": tool_use_id, "content": inner}


def _text_part(text: str) -> dict[str, Any]:
    return {"type": "text", "text": text}


# ---------------------------------------------------------------------------
# ATTACK A — the extractor diverges from the message view on text-typed blocks
# ---------------------------------------------------------------------------


def test_R1f_P2_a_text_typed_body_is_refused_where_the_view_reads_it() -> None:
    """ATTACK (P2), extractor divergence: the message view reads the text of
    ANY block (`_content_text`), while `_receipt_row_body_text` reads only
    blocks typed `tool_result`.

    On a row whose content is a list of TEXT blocks the two disagree: the
    view's criterion admits it, the raw scan refuses it. Filed P2/记档
    because the shape needs a `toolUseResult` attached to a text-typed
    content — the receipt shapes the CLI writes are the bare string and the
    `tool_result` block — but it is a real parity gap in the criterion the
    c1f repair was written to close."""

    inner = [_text_part(RECEIPT_TEXT)]
    # The message view's channel: `result` is what it hands the predicate.
    assert _content_text(inner) == RECEIPT_TEXT
    assert is_async_agent_receipt(None, _content_text(inner)) is True
    assert is_async_agent_receipt(
        None, _result_text(inner)
    ) is True

    # The raw scan, same text, refuses it.
    row = _row(content=inner, tool_use_result={})
    assert _receipt_row_body_text(row) is None
    assert _is_receipt_row(row) is False


def test_R1f_control_a_bare_string_inner_entry_is_read_by_the_raw_side_only() -> None:
    """The mirror of that divergence: `_tool_result_texts` accepts a bare
    string entry inside the block's content, `_content_text` does not. This is
    the raw side being MORE permissive, on a shape with no metadata status to
    anchor it (see the declared channel below)."""

    inner = [RECEIPT_TEXT]
    row = _row(content=[_tool_result_block(inner)], tool_use_result={})

    assert _tool_result_entry_readable(inner) is True
    assert _receipt_row_body_text(row) == RECEIPT_TEXT
    # The view would see no text at all for the same inner content.
    assert _content_text(inner) is None


def _tool_result_entry_readable(inner: Any) -> bool:
    from connector.runtimes.claude.sessions.subagent_oracle import _tool_result_texts

    return bool(_tool_result_texts(inner))


# ---------------------------------------------------------------------------
# ATTACK B — the status branches of the repaired gate
# ---------------------------------------------------------------------------


def test_R1f_control_a_status_less_receipt_still_lands_via_wording() -> None:
    """CONTROL, the no-miss direction: real receipts that carry no status in
    their metadata are admitted on the wording, exactly as the message view
    admits them. The repair must not have cost F5 its anchor."""

    row = _row(
        content=[_tool_result_block([_text_part(RECEIPT_TEXT)])],
        tool_use_result={},
    )
    assert _is_receipt_row(row) is True
    assert scan_raw_transcript((json.dumps(row),)).receipt_times_ms[TASK_ID] == NOW_MS


def test_R1f_control_an_explicit_non_async_status_is_refused_despite_wording() -> None:
    """CONTROL, the R1e-2 repair itself: an explicit non-async status is the
    call's outcome, and the wording in the body cannot overturn it — the same
    verdict the message view reaches on the identical metadata."""

    metadata = {"status": "completed"}
    row = _row(
        content=[_tool_result_block([_text_part(f"done — {RECEIPT_TEXT}")])],
        tool_use_result=metadata,
    )
    assert _is_receipt_row(row) is False
    assert is_async_agent_receipt(metadata, RECEIPT_TEXT) is False


def test_R1f_control_an_explicit_async_status_is_admitted_without_wording() -> None:
    """CONTROL: an explicit `async_launched` decides on its own — a body with
    no receipt wording (even no text at all) is admitted, which is exactly
    what `is_async_agent_receipt` does in the message view."""

    metadata = {"status": "async_launched"}
    assert is_async_agent_receipt(metadata, None) is True
    assert (
        _is_receipt_row(_row(content=[_tool_result_block([])], tool_use_result=metadata))
        is True
    )
    assert _is_receipt_row(_row(content="", tool_use_result=metadata)) is True


def test_R1f_control_an_unreadable_body_with_no_status_is_refused() -> None:
    """CONTROL: with no status to decide, a row whose text cannot be read is
    refused rather than trusted on the metadata alone — the c1f docstring's
    rule, and the message view agrees (no text, no status, no receipt)."""

    row = _row(content=[{"type": "image", "source": {"data": "…"}}], tool_use_result={})
    assert _receipt_row_body_text(row) is None
    assert _is_receipt_row(row) is False
    assert is_async_agent_receipt({}, None) is False


def test_R1f_control_the_docstring_overstates_the_unreadable_body_case() -> None:
    """RECORDED (doc nit, not a defect): the c1f docstring says "a row whose
    text cannot be read is refused rather than trusted on the metadata alone",
    but that holds only when the metadata names no status. With an explicit
    `async_launched` the metadata IS trusted on its own — correctly, since
    that is what the message view does — so the sentence should say
    "status-less metadata"."""

    metadata = {"status": "async_launched"}
    row = _row(content=[{"type": "image", "source": {}}], tool_use_result=metadata)
    assert _receipt_row_body_text(row) is None
    assert _is_receipt_row(row) is True  # trusted on the metadata alone


# ---------------------------------------------------------------------------
# ATTACK C — multi-block and non-Mapping shapes
# ---------------------------------------------------------------------------


def test_R1f_control_multiple_tool_result_blocks_join_in_order() -> None:
    """CONTROL: several `tool_result` blocks are concatenated in order with a
    newline, which is the same join `_content_text` uses. Only the first
    block's text can therefore carry the prefix — a receipt in a later block
    is refused, on both sides."""

    row = _row(
        content=[
            _tool_result_block([_text_part("first")], tool_use_id="call_1"),
            _tool_result_block([_text_part(RECEIPT_TEXT)], tool_use_id="call_2"),
        ],
        tool_use_result={},
    )
    assert _receipt_row_body_text(row) == f"first\n{RECEIPT_TEXT}"
    assert _is_receipt_row(row) is False  # the prefix is no longer leading

    leading = _row(
        content=[
            _tool_result_block([_text_part(RECEIPT_TEXT)], tool_use_id="call_1"),
            _tool_result_block([_text_part("tail")], tool_use_id="call_2"),
        ],
        tool_use_result={},
    )
    assert _is_receipt_row(leading) is True


def test_R1f_control_non_mapping_entries_are_skipped_by_both_sides() -> None:
    """CONTROL: entries that are neither strings nor mappings contribute
    nothing on either side."""

    inner = [123, None, _text_part(RECEIPT_TEXT)]
    row = _row(content=[_tool_result_block(inner)], tool_use_result={})

    assert _receipt_row_body_text(row) == RECEIPT_TEXT
    assert _content_text(inner) == RECEIPT_TEXT


def test_R1f_control_non_mapping_content_is_unreadable() -> None:
    """CONTROL: a content that is neither a string nor a list yields no text
    on the raw side (and `_content_text` agrees)."""

    for content in (123, {"type": "text", "text": RECEIPT_TEXT}, None, True):
        row = _row(content=content, tool_use_result={})
        assert _receipt_row_body_text(row) is None, content
        assert _is_receipt_row(row) is False, content


# ---------------------------------------------------------------------------
# ATTACK D — did the fallback widen the declared paste channel?
# ---------------------------------------------------------------------------


def test_R1f_control_a_status_less_metadata_does_not_widen_the_paste_channel() -> None:
    """ATTACK that does NOT land: the status-less fallback keeps the exact
    criterion the R4-2/R1e-3 declaration describes.

    A human pasting the receipt wording verbatim is admitted when the row
    carries status-less metadata AND when it carries none at all — the same
    one rule (wording), so the repair did not open a second way in. And the
    plain mention, with or without status-less metadata, stays refused."""

    paste = _row(
        content=[_tool_result_block([_text_part(RECEIPT_TEXT)])],
        tool_use_result={},
    )
    assert _is_receipt_row(paste) is True
    # Without any metadata at all: the already-declared bare channel.
    assert _is_receipt_row(_row(content=RECEIPT_TEXT)) is True

    mention = f"what happened to agentId: {TASK_ID}?"
    # Every status-less metadata shape the repaired branch can receive. (A row
    # with NO metadata at all takes the deliberately ungated `tool_result`
    # block channel instead — the engine's own shape, and not what a human
    # types; that path is pinned by the five-shape control below.)
    for metadata in ({}, {"status": None}, {"other": 1}):
        row = _row(
            content=[_tool_result_block([_text_part(mention)])],
            tool_use_result=metadata,
        )
        assert _is_receipt_row(row) is False, metadata


def test_R1f_control_the_five_real_shapes_keep_their_verdicts() -> None:
    """CONTROL: the shapes the scan must and must not admit, all in one place."""

    cases: tuple[tuple[str, dict[str, Any], bool], ...] = (
        # engine: bare F5 body
        ("f5-bare", _row(content=RECEIPT_TEXT), True),
        # engine: metadata-less tool_result block
        (
            "bare-block",
            _row(content=[_tool_result_block([_text_part(RECEIPT_TEXT)])]),
            True,
        ),
        # engine: explicit async status
        (
            "async-status",
            _row(
                content=[_tool_result_block([_text_part("launched")])],
                tool_use_result={"status": "async_launched"},
            ),
            True,
        ),
        # outcome: explicit sync status
        (
            "sync-status",
            _row(
                content=[_tool_result_block([_text_part(f"report about {TASK_ID}")])],
                tool_use_result={"status": "completed"},
            ),
            False,
        ),
        # human: a plain mention
        ("mention", _row(content=f"notes on agentId: {TASK_ID}"), False),
    )
    for name, row, expected in cases:
        assert _is_receipt_row(row) is expected, name

def test_R1f_the_flipped_guard_is_not_hollow_green() -> None:
    """The flipped guard (`..._a_sync_agents_result_row_is_refused_as_a_receipt`)
    is keyed to the c1f repair: under the pre-c1f rule the very same row is a
    receipt, so the guard could not have passed before the fix."""

    metadata = {"status": "completed"}
    row = _row(
        content=[_tool_result_block([_text_part(f"done, agentId: {TASK_ID}")])],
        tool_use_result=metadata,
    )

    def _pre_c1f_is_receipt_row(candidate: Any) -> bool:
        # The d5db6422 logic, inline: metadata presence was the whole test.
        if candidate.get("type") != "user":
            return False
        return isinstance(candidate.get("toolUseResult"), dict)

    assert _is_receipt_row(row) is False
    assert _pre_c1f_is_receipt_row(row) is True
