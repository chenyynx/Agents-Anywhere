from __future__ import annotations

import json
from collections.abc import Mapping
from typing import Any

from sqlalchemy import and_, case, delete, insert, literal, not_, or_, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine

from agent_server.core.models import TimelineItem
from agent_server.infra.db import timeline_items

#: Item statuses that leave an Agent card active, positively enumerated from
#: the protocol's ``TimelineStatus`` literal (core/models.py). Mirrors the
#: client's phase mapping (iOS ``SubAgentPhase.from``: ``pending``/``running``/
#: ``waiting_approval`` are the live phases; ``done``/``failed``/``cancelled``/
#: ``interrupted`` are terminal). Keep this a positive list rather than a
#: negation of the terminal set: a status a future protocol adds is then never
#: silently advertised as an active card.
_ACTIVE_AGENT_CARD_STATUSES = frozenset({"pending", "running", "waiting_approval"})

#: Statuses whose timeline row is still moving. A deferred window never
#: summarises one: it is the live tail the reader is watching, its next frame
#: carries the complete row anyway, and ``waiting_approval`` also seats an
#: interaction surface. Active rows are the one deliberate exception to the
#: byte budget.
ACTIVE_TIMELINE_STATUSES = frozenset({"pending", "running", "waiting_approval"})

#: Format version of the deferred-activity stub written to ``stub_json``
#: (v2_48). A reader must ignore a stub whose version it does not know and
#: fall back to the full payload.
STUB_VERSION = 1
#: Byte budget for a stub's ``content`` object. The stub exists so a window
#: reader never parses a multi-megabyte payload to render one collapsed line;
#: 2048 bytes holds every title field with room for a tail preview.
STUB_MAX_BYTES = 2048

#: Hard cap on the rows one deferred-activity window carries, activity rows
#: included. The window is anchored on display rows (``limit`` of them) and
#: grows over the activity rows between them; without a row cap a session that
#: emitted hundreds of tool calls between two messages would still read them
#: all. The oldest rows past the cap are dropped and reported through
#: ``has_more`` so the client can page back through history.
DEFERRED_WINDOW_MAX_ROWS = 800
#: A main-timeline tool activity row larger than this is served from
#: ``stub_json`` (the writer's render-ready summary) instead of its full
#: payload. Below the threshold the full payload is cheaper than a second
#: column read and keeps the row expandable without a second request.
DEFERRED_STUB_THRESHOLD_BYTES = 8192
#: The newest activity segment (every row after the newest display row) stays
#: complete up to this many bytes; past it the API summarises its oldest rows
#: first. The segment is what the user is looking at right now, so it is kept
#: full as long as it fits inside one mobile response comfortably.
DEFERRED_TAIL_FULL_BYTES = 262144
#: How many of the newest main rows the anchor query may scan to find the
#: ``limit`` display rows it anchors on. Bounds the scan on a session whose
#: newest thousands of rows are all activity.
DEFERRED_ANCHOR_SCAN_ROWS = 3000

#: Content kinds that render as a row of their own in the main timeline. A
#: tool row of one of these kinds is a display row: it is counted toward the
#: window's ``limit`` and is never summarised.
_DEFERRED_DISPLAY_CONTENT_KINDS = frozenset(
    {"file_change", "agent_call", "input_request"}
)
#: Row types that never render in a timeline window; they are neither counted
#: nor treated as activity.
_DEFERRED_HIDDEN_TYPES = frozenset({"turn.start", "turn.end"})

#: Keys that only exist for the expanded view. Their content is what makes a
#: tool payload large; the stub keeps a bounded tail preview instead.
_DEFERRED_DROP_KEYS = (
    "output",
    "outputText",
    "text",
    "result",
    "arguments",
    "details",
    "changes",
    "rawText",
)
#: ``input`` fields a collapsed row may render (paths, commands, queries).
_STUB_INPUT_KEYS = (
    "file_path",
    "path",
    "filePath",
    "file",
    "uri",
    "notebook_path",
    "query",
    "url",
    "command",
    "cmd",
    "description",
    "pattern",
    "glob",
    "subagent_type",
    "run_in_background",
    "timeout",
    "limit",
    "offset",
)
_STUB_INPUT_STRING_LIMIT = 200
_STUB_OUTPUT_PREVIEW_LIMIT = 240
_STUB_OUTPUT_BINARY_WINDOW = 4000
#: String limits applied to required fields, in order, when the stub still
#: exceeds ``STUB_MAX_BYTES`` after every optional key was dropped.
_STUB_REQUIRED_STRING_LIMITS = (200, 100, 50)
#: Keys a stub must keep even when it has to shrink to ``STUB_MAX_BYTES``:
#: they are what the collapsed row renders, so dropping them would leave a
#: blank line. Everything else — including ``input`` — is optional and goes
#: largest-first; the row still expands through ``deferred=true``.
_STUB_REQUIRED_KEYS = frozenset(
    {
        "kind",
        "name",
        "toolName",
        "tool",
        "title",
        "description",
        "command",
        "outputLength",
        "toolUseId",
        "isError",
        "deferred",
        "deferredBytes",
        "outputPreview",
    }
)


def _json_dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def content_kind(content: Any) -> str | None:
    """``content.kind`` when it is a non-empty string, else ``None``.

    Mirrored into the ``kind`` column (v2_48). Total by construction: content
    is free JSON, so anything but a non-empty string stores NULL rather than
    being guessed — the same rule the migration backfill applies.
    """

    if not isinstance(content, Mapping):
        return None
    value = content.get("kind")
    return value if isinstance(value, str) and value else None


def is_deferred_reasoning_row(*, item_type: str, kind: str | None) -> bool:
    """Whether a row is a reasoning row (``system`` with ``kind='reasoning'``).

    Reasoning is an activity row: the timeline renders it, but it is not one of
    the display rows a window is anchored on. ``type='reasoning'`` is accepted
    too — no current writer emits it, but stored rows from an older projection
    may carry it and the classification must stay total over the table.
    """

    return item_type == "reasoning" or (
        item_type == "system" and kind == "reasoning"
    )


def is_deferred_activity_row(
    *,
    item_type: str,
    status: str | None,
    kind: str | None,
    parent_item_id: str | None = None,
) -> bool:
    """Whether a row is *activity*: carried by the window, never counted.

    Two shapes qualify (``parent_item_id`` is the row's mirrored
    ``content.parentItemId`` column):

    - a reasoning row — always activity;
    - a main-timeline tool row whose ``kind`` is present, is not one of the
      display kinds, and whose status is not ``waiting_approval``. A tool row
      awaiting approval is a prompt the user must see, so it is a display row.

    A tool row with ``kind IS NULL`` (written before v2_48 mirrored ``kind``)
    is a display row: during a rolling upgrade the reader must not silently
    collapse a row it cannot classify.

    Keep this predicate and :func:`_deferred_activity_row_expr` in lockstep;
    ``tests/test_timeline_deferred_window.py`` pins the two together.
    """

    if is_deferred_reasoning_row(item_type=item_type, kind=kind):
        return True
    if item_type != "tool" or parent_item_id is not None:
        return False
    if kind is None or kind in _DEFERRED_DISPLAY_CONTENT_KINDS:
        return False
    return status != "waiting_approval"


def is_deferred_display_row(
    *,
    item_type: str,
    status: str | None,
    kind: str | None,
    parent_item_id: str | None = None,
) -> bool:
    """Whether a main row is a *display* row: counted, never summarised.

    Only a main row (no ``parent_item_id``) that is not activity, not a turn
    boundary and not an artifact diff is a display row. The window's ``limit``
    counts exactly these; everything else rides along (or is excluded).
    """

    if parent_item_id is not None:
        return False
    if is_deferred_activity_row(
        item_type=item_type,
        status=status,
        kind=kind,
        parent_item_id=parent_item_id,
    ):
        return False
    if item_type in _DEFERRED_HIDDEN_TYPES:
        return False
    if item_type == "artifact" and kind == "diff":
        return False
    return True


def is_deferred_activity_item(item: TimelineItem) -> bool:
    """``is_deferred_activity_row`` for one stored payload object."""

    return is_deferred_activity_row(
        item_type=item.type,
        status=item.status,
        kind=content_kind(item.content),
        parent_item_id=_parent_item_id(item),
    )


def is_deferred_display_item(item: TimelineItem) -> bool:
    """``is_deferred_display_row`` for one stored payload object."""

    return is_deferred_display_row(
        item_type=item.type,
        status=item.status,
        kind=content_kind(item.content),
        parent_item_id=_parent_item_id(item),
    )


def is_deferred_reasoning_item(item: TimelineItem) -> bool:
    """``is_deferred_reasoning_row`` for one stored payload object."""

    return is_deferred_reasoning_row(
        item_type=item.type,
        kind=content_kind(item.content),
    )


def _deferred_activity_row_expr(columns: Any) -> Any:
    """SQL mirror of :func:`is_deferred_activity_row`.

    ``columns`` is either ``timeline_items.c`` or the column collection of the
    anchor-scan subquery, so the same predicate drives the stored table and the
    recent-main-rows scan.
    """

    return or_(
        columns.type == "reasoning",
        and_(columns.type == "system", columns.kind == "reasoning"),
        and_(
            columns.type == "tool",
            columns.parent_item_id.is_(None),
            columns.kind.is_not(None),
            columns.kind.not_in(sorted(_DEFERRED_DISPLAY_CONTENT_KINDS)),
            columns.status != "waiting_approval",
        ),
    )


def _deferred_display_row_expr(columns: Any) -> Any:
    """SQL mirror of :func:`is_deferred_display_row`."""

    return and_(
        columns.parent_item_id.is_(None),
        not_(_deferred_activity_row_expr(columns)),
        columns.type.not_in(sorted(_DEFERRED_HIDDEN_TYPES)),
        # NULL-safe ``NOT (artifact AND kind='diff')``: SQL three-valued logic
        # would drop an artifact row whose kind is NULL, while the Python
        # predicate keeps it as a display row (a hidden diff is the only
        # artifact the timeline suppresses).
        or_(
            columns.type != "artifact",
            columns.kind.is_(None),
            columns.kind != "diff",
        ),
    )


def _looks_binary_output(text: str) -> bool:
    """Whether raw output is more likely base64/binary than readable text."""

    head = text[:_STUB_OUTPUT_BINARY_WINDOW]
    if "base64" in head or "media_type" in head:
        return True
    tail = text[-_STUB_OUTPUT_PREVIEW_LIMIT:]
    return not any(character.isspace() for character in tail)


def _output_preview(content: Mapping[str, Any]) -> str | None:
    raw = content.get("output") or content.get("outputText") or content.get("text")
    if not isinstance(raw, str) or not raw:
        return None
    if _looks_binary_output(raw):
        return None
    return raw[-_STUB_OUTPUT_PREVIEW_LIMIT:]


def _trim_stub_input(value: Any) -> Any | None:
    """Bound ``input`` to what a collapsed row may render (``None`` = drop).

    A string input is truncated; any other non-mapping value cannot be
    whitelisted and is dropped outright, so it can never carry the stub past
    the byte budget.
    """

    if isinstance(value, str):
        return value[:_STUB_INPUT_STRING_LIMIT]
    if not isinstance(value, Mapping):
        return None
    trimmed: dict[str, Any] = {}
    for key in _STUB_INPUT_KEYS:
        if key not in value:
            continue
        item = value[key]
        if isinstance(item, str) and len(item) > _STUB_INPUT_STRING_LIMIT:
            item = item[:_STUB_INPUT_STRING_LIMIT]
        trimmed[key] = item
    return trimmed


def _value_size(key: str, value: Any) -> int:
    return len(_json_dumps({key: value}).encode("utf-8"))


def _stub_size(stub: Mapping[str, Any]) -> int:
    return len(_json_dumps(stub).encode("utf-8"))


def _shrink_required_strings(stub: dict[str, Any]) -> None:
    """Truncate required string fields (200 → 100 → 50) until the stub fits.

    Dropping every optional key can still leave a stub over budget when a
    required field itself is huge (a 3 KB ``title``/``command``). The title
    line must not go blank, so the required strings shrink stepwise instead.
    If even the 50-character forms do not fit — they always do for the
    protocol's fixed field set, this is a theoretical guard — the over-limit
    stub is kept as is rather than emptying what the row renders.
    """

    if _stub_size(stub) <= STUB_MAX_BYTES:
        return
    for limit in _STUB_REQUIRED_STRING_LIMITS:
        truncated = False
        for key, value in stub.items():
            if (
                key in _STUB_REQUIRED_KEYS
                and isinstance(value, str)
                and len(value) > limit
            ):
                stub[key] = value[:limit]
                truncated = True
        if truncated and _stub_size(stub) <= STUB_MAX_BYTES:
            return


def build_stub_content(content: Any, payload_bytes: int) -> dict[str, Any] | None:
    """A small render-ready copy of one item's ``content``.

    Returns ``None`` when there is no content to summarize (not a mapping, or
    empty). Otherwise: drops the bulk output keys, keeps a 240-character tail
    preview when the output is readable text, bounds ``input`` to the fields a
    collapsed row renders, marks the content ``deferred`` with the full payload
    size, then shrinks optional keys largest-first and required strings
    stepwise until the serialized stub fits ``STUB_MAX_BYTES``.

    The wrapped item keeps the original ``revision``/``updatedSeq`` (the
    client's supersede rule needs them) and the original ``contentHash`` (it
    describes the complete content, exactly as the protocol defines it), while
    ``content.deferred`` marks the body as summarised.

    ``v2_48._build_stub_content`` is a verbatim copy of this function (a
    migration cannot import application code); ``tests/test_timeline_stub_payload.py``
    holds the two together with a parity test.
    """

    if not isinstance(content, Mapping) or not content:
        return None
    stub = dict(content)
    preview = _output_preview(content)
    for key in _DEFERRED_DROP_KEYS:
        stub.pop(key, None)
    if "input" in stub:
        trimmed_input = _trim_stub_input(stub["input"])
        if trimmed_input is None:
            stub.pop("input")
        else:
            stub["input"] = trimmed_input
    if preview is not None:
        stub["outputPreview"] = preview
    stub["deferred"] = True
    stub["deferredBytes"] = payload_bytes
    candidates = [key for key in stub if key not in _STUB_REQUIRED_KEYS]
    candidates.sort(key=lambda key: (-_value_size(key, stub[key]), key))
    for key in candidates:
        if _stub_size(stub) <= STUB_MAX_BYTES:
            break
        del stub[key]
    _shrink_required_strings(stub)
    return stub


#: Head of a reasoning row kept in its budget-trim summary. Long enough to
#: read the opening thought, short enough that the stub stays far below the
#: per-item ceiling.
REASONING_STUB_TEXT_LIMIT = 1000


def _reasoning_text(content: Mapping[str, Any]) -> str:
    """The text the Chat page renders for a reasoning row."""

    summaries = content.get("summaries")
    if isinstance(summaries, list):
        parts = []
        for entry in summaries:
            if isinstance(entry, Mapping):
                value = entry.get("text")
                if isinstance(value, str) and value:
                    parts.append(value)
        if parts:
            return "\n\n".join(parts)
    for key in ("rawText", "text", "summary"):
        value = content.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def build_reasoning_stub_content(
    content: Any, payload_bytes: int
) -> dict[str, Any] | None:
    """A thinking row's budget-trim summary: a readable text head.

    The Chat page hides a reasoning row whose text is empty, so the tool-style
    stub (which drops ``text``) cannot stand in for one. This summary keeps the
    row visible with the opening thought and ``deferred=true``; expanding it
    fetches the full row through the single-item read. Used only as the budget
    trim's last resort — normal windows keep reasoning complete.
    """

    if not isinstance(content, Mapping) or not content:
        return None
    text = _reasoning_text(content)
    if not text:
        return None
    stub: dict[str, Any] = {}
    kind = content.get("kind")
    if isinstance(kind, str) and kind:
        stub["kind"] = kind
    fmt = content.get("format")
    if isinstance(fmt, str) and fmt:
        stub["format"] = fmt
    limit = REASONING_STUB_TEXT_LIMIT
    while True:
        preview = text[:limit]
        if limit < len(text):
            preview += "…"
        stub["text"] = preview
        stub["deferred"] = True
        stub["deferredBytes"] = payload_bytes
        if _stub_size(stub) <= STUB_MAX_BYTES or limit <= 100:
            return stub
        limit //= 2


class SqlTimelineStore:
    def __init__(self, engine: AsyncEngine) -> None:
        self._engine = engine

    async def read(self, session_id: str) -> list[TimelineItem]:
        async with self._engine.connect() as conn:
            rows = (
                await conn.execute(
                    timeline_items.select()
                    .where(timeline_items.c.session_id == session_id)
                    .order_by(
                        timeline_items.c.order_seq,
                        timeline_items.c.updated_seq,
                        timeline_items.c.id,
                    )
                )
            ).mappings().all()
        return [TimelineItem.model_validate_json(row["payload_json"]) for row in rows]

    async def recovery_items(
        self, session_id: str, *, limit: int = 100,
    ) -> tuple[list[TimelineItem], bool]:
        """Probe IDs first; caller holds the session revision fence."""
        async with self._engine.connect() as conn:
            ids = (await conn.execute(
                select(timeline_items.c.id)
                .where(timeline_items.c.session_id == session_id)
                .limit(limit + 1)
            )).scalars().all()
        if len(ids) > limit:
            return [], True
        items = await self.read_many(session_id, set(ids))
        items.sort(key=lambda item: (item.orderSeq, item.updatedSeq, item.id))
        return items, False

    async def replace(self, session_id: str, items: list[TimelineItem]) -> None:
        async with self._engine.begin() as conn:
            await self.replace_all(conn, session_id, items)

    async def delete_items(
        self,
        conn: AsyncConnection,
        session_id: str,
        item_ids: set[str],
    ) -> None:
        """Delete the given stable IDs inside the caller's transaction."""

        ids = list(item_ids)
        for offset in range(0, len(ids), 500):
            await conn.execute(
                delete(timeline_items).where(
                    timeline_items.c.session_id == session_id,
                    timeline_items.c.id.in_(ids[offset : offset + 500]),
                )
            )

    async def replace_all(
        self,
        conn: AsyncConnection,
        session_id: str,
        items: list[TimelineItem],
    ) -> None:
        """Replace one complete timeline inside the caller's transaction."""

        await conn.execute(
            delete(timeline_items).where(timeline_items.c.session_id == session_id)
        )
        if not items:
            return
        sorted_items = sorted(
            items,
            key=lambda value: (value.orderSeq, value.updatedSeq, value.id),
        )
        await conn.execute(
            insert(timeline_items),
            [self._row_values(item) for item in sorted_items],
        )

    async def latest_item(self, session_id: str) -> TimelineItem | None:
        async with self._engine.connect() as conn:
            row = (
                await conn.execute(
                    timeline_items.select()
                    .where(timeline_items.c.session_id == session_id)
                    .order_by(
                        timeline_items.c.item_time.desc(),
                        timeline_items.c.order_seq.desc(),
                        timeline_items.c.updated_seq.desc(),
                    )
                    .limit(1)
                )
            ).mappings().first()
        return TimelineItem.model_validate_json(row["payload_json"]) if row is not None else None

    async def upsert_one(self, conn: AsyncConnection, item: TimelineItem) -> None:
        """Insert-or-update a single row by composite PK (session_id, id).

        Hot path: called per streaming Codex delta. Avoids the O(N) DELETE-all
        + INSERT-all pattern that `replace()` does. The ``ON CONFLICT`` upsert
        keeps it to one row mutation.
        """
        await self.upsert_many(conn, [item])

    async def upsert_many(
        self,
        conn: AsyncConnection,
        items: list[TimelineItem],
    ) -> None:
        """Insert or update one Runtime timeline batch by stable IDs."""

        if not items:
            return
        values = [self._row_values(item) for item in items]
        stmt = pg_insert(timeline_items)
        update_cols = {
            key: stmt.excluded[key]
            for key in values[0]
            if key not in ("session_id", "id")
        }
        stmt = stmt.on_conflict_do_update(
            index_elements=["session_id", "id"],
            set_=update_cols,
            where=stmt.excluded.updated_seq >= timeline_items.c.updated_seq,
        )
        await conn.execute(stmt, values)

    async def read_one(
        self, session_id: str, item_id: str
    ) -> TimelineItem | None:
        async with self._engine.connect() as conn:
            row = (
                await conn.execute(
                    timeline_items.select().where(
                        timeline_items.c.session_id == session_id,
                        timeline_items.c.id == item_id,
                    )
                )
            ).mappings().first()
        return TimelineItem.model_validate_json(row["payload_json"]) if row is not None else None

    async def read_many(
        self,
        session_id: str,
        item_ids: set[str],
    ) -> list[TimelineItem]:
        """Read only the rows touched by one incremental Runtime sync."""

        if not item_ids:
            return []
        rows = []
        item_id_list = list(item_ids)
        async with self._engine.connect() as conn:
            for offset in range(0, len(item_id_list), 500):
                chunk = item_id_list[offset : offset + 500]
                rows.extend(
                    (
                        await conn.execute(
                            timeline_items.select().where(
                                timeline_items.c.session_id == session_id,
                                timeline_items.c.id.in_(chunk),
                            )
                        )
                    ).mappings().all()
                )
        return [TimelineItem.model_validate_json(row["payload_json"]) for row in rows]

    async def list_since(
        self, session_id: str, *, after_seq: int, limit: int
    ) -> tuple[list[TimelineItem], bool]:
        async with self._engine.connect() as conn:
            rows = (
                await conn.execute(
                    timeline_items.select()
                    .where(
                        timeline_items.c.session_id == session_id,
                        timeline_items.c.updated_seq > after_seq,
                    )
                    .order_by(timeline_items.c.updated_seq)
                    .limit(limit + 1)
                )
            ).mappings().all()
        has_more = len(rows) > limit
        items = [TimelineItem.model_validate_json(row["payload_json"]) for row in rows[:limit]]
        return items, has_more

    async def list_latest(
        self,
        session_id: str,
        *,
        limit: int,
        main_only: bool = False,
    ) -> tuple[list[TimelineItem], bool]:
        """The newest ``limit`` rows, oldest first.

        ``main_only`` drops subagent child rows (``parent_item_id`` set) in
        SQL, *before* the LIMIT. Filtering afterwards would let a window made
        entirely of child rows come back empty even though the session has
        main-timeline content — the exact session-open blank page this opt-in
        reader exists for.
        """

        statement = timeline_items.select().where(
            timeline_items.c.session_id == session_id
        )
        if main_only:
            statement = statement.where(
                timeline_items.c.parent_item_id.is_(None)
            )
        async with self._engine.connect() as conn:
            rows = (
                await conn.execute(
                    statement.order_by(
                        timeline_items.c.order_seq.desc(),
                        timeline_items.c.updated_seq.desc(),
                        timeline_items.c.id.desc(),
                    ).limit(limit + 1)
                )
            ).mappings().all()
        has_more = len(rows) > limit
        items = [TimelineItem.model_validate_json(row["payload_json"]) for row in rows[:limit]]
        items.reverse()
        return items, has_more

    async def list_before_order_seq(
        self,
        session_id: str,
        *,
        before_order_seq: int,
        limit: int,
        main_only: bool = False,
    ) -> tuple[list[TimelineItem], bool]:
        """One history page ending before ``before_order_seq``, oldest first.

        ``main_only`` has the same meaning as in ``list_latest``: child rows
        are excluded in SQL before the LIMIT, so a page is filled with main
        rows rather than a filtered subset of an arbitrary window.
        """

        statement = timeline_items.select().where(
            timeline_items.c.session_id == session_id,
            timeline_items.c.order_seq < before_order_seq,
        )
        if main_only:
            statement = statement.where(
                timeline_items.c.parent_item_id.is_(None)
            )
        async with self._engine.connect() as conn:
            rows = (
                await conn.execute(
                    statement.order_by(
                        timeline_items.c.order_seq.desc(),
                        timeline_items.c.updated_seq.desc(),
                        timeline_items.c.id.desc(),
                    ).limit(limit + 1)
                )
            ).mappings().all()
        has_more = len(rows) > limit
        items = [TimelineItem.model_validate_json(row["payload_json"]) for row in rows[:limit]]
        items.reverse()
        return items, has_more

    async def list_deferred_window(
        self,
        session_id: str,
        *,
        limit: int,
        before_order_seq: int | None = None,
        span_rows: int = DEFERRED_WINDOW_MAX_ROWS,
        anchor_scan_rows: int = DEFERRED_ANCHOR_SCAN_ROWS,
        stub_threshold_bytes: int = DEFERRED_STUB_THRESHOLD_BYTES,
    ) -> tuple[list[TimelineItem], bool, bool]:
        """An activity-aware window anchored on the newest display rows.

        A session's newest rows are often all tool/reasoning activity (measured:
        56 tool + 44 reasoning, zero messages), so a plain ``limit`` reader
        spends the whole page on rows the client collapses to one line. This
        reader spends ``limit`` on *display* rows instead — messages, artifacts,
        Agent cards, approvals, file changes — and rides the activity rows
        between them along, up to ``span_rows`` rows in total.

        Two queries, both restricted to main rows (``parent_item_id IS NULL``;
        a child message inside an Agent card must never become the anchor):

        1. **Anchor.** Scan the newest ``anchor_scan_rows`` main rows (honouring
           ``before_order_seq`` for history paging), filter to display rows in
           the subquery, and take the newest ``limit``. The smallest
           ``order_seq`` found is where the window starts. If the window's
           span cap would start above the newest display row (a very long
           activity tail), the read declines (``applied=False``) instead of
           returning a conversation-free page.
        2. **Window.** Every main row at or above the anchor — and, for a
           history read, strictly below ``before_order_seq`` — newest first,
           capped at ``span_rows``, returned ascending. The cursor bound is what
           keeps a history page from re-serving rows the client already holds
           (and from letting the budget trim drop the oldest rows, which are the
           only ones that page exists to fetch). Each row's payload is chosen
           in SQL so a summarised tool row never reads its full payload:
           activity rows below the stub threshold come back complete, a larger
           main tool activity row comes from ``stub_json`` (only when it
           carries the current ``stub_version``). Active rows (``pending`` /
           ``running`` / ``waiting_approval``) always stay complete: their
           next frame carries the whole row, and ``waiting_approval`` also
           seats an interaction surface.

        ``has_more`` reports whether any main row exists *before* the oldest
        returned row, compared on the full ``(order_seq, updated_seq, id)``
        boundary — ``order_seq`` alone would report "no more" for a row tied
        with the page's first row and skip it. The client-side cursor remains
        the existing single ``order_seq``; the write buffer normalizes the
        sequence within a session, so a tie at the cursor is not reachable
        through the product path (a synthetic tie would still be unreachable
        through that cursor — an existing limitation of every timeline page).

        Returns ``(items_ascending, has_more, applied)``. ``applied=False``
        (no display row in the scan) tells the API to fall back to the
        pre-existing reader, so a session the feature cannot serve keeps its
        exact old behavior.
        """

        if limit <= 0 or span_rows <= 0 or anchor_scan_rows <= 0:
            return [], False, False

        recent_columns = (
            timeline_items.c.order_seq,
            timeline_items.c.type,
            timeline_items.c.status,
            timeline_items.c.kind,
            timeline_items.c.parent_item_id,
        )
        recent = select(*recent_columns).where(
            timeline_items.c.session_id == session_id,
            timeline_items.c.parent_item_id.is_(None),
        )
        if before_order_seq is not None:
            recent = recent.where(
                timeline_items.c.order_seq < before_order_seq
            )
        recent = (
            recent.order_by(
                timeline_items.c.order_seq.desc(),
                timeline_items.c.updated_seq.desc(),
                timeline_items.c.id.desc(),
            )
            .limit(anchor_scan_rows)
            .subquery()
        )
        anchor_statement = (
            select(recent.c.order_seq)
            .where(_deferred_display_row_expr(recent.c))
            .order_by(recent.c.order_seq.desc())
            .limit(limit)
        )

        stub_eligible = and_(
            timeline_items.c.type == "tool",
            timeline_items.c.parent_item_id.is_(None),
            timeline_items.c.kind.is_not(None),
            timeline_items.c.kind.not_in(
                sorted(_DEFERRED_DISPLAY_CONTENT_KINDS)
            ),
            # The newest frame of an active row is the whole row; a stale
            # summary would also fight the live update. Keep it complete.
            timeline_items.c.status.not_in(sorted(ACTIVE_TIMELINE_STATUSES)),
            timeline_items.c.payload_bytes.is_not(None),
            timeline_items.c.payload_bytes > stub_threshold_bytes,
            timeline_items.c.stub_json.is_not(None),
            timeline_items.c.stub_version == STUB_VERSION,
        )
        async with self._engine.connect() as conn:
            anchored = (await conn.execute(anchor_statement)).scalars().all()
            if not anchored:
                return [], False, False
            anchor = min(anchored)
            newest_counted = max(anchored)

            # If the newest counted row is older than the oldest row the span
            # keeps, the span holds only activity rows: the reader would come
            # back with no conversational anchor at all. Report "not applied"
            # so the API keeps its pre-existing bounded reader instead of
            # serving a full-payload activity tail.
            boundary_filters = [
                timeline_items.c.session_id == session_id,
                timeline_items.c.parent_item_id.is_(None),
            ]
            if before_order_seq is not None:
                boundary_filters.append(
                    timeline_items.c.order_seq < before_order_seq
                )
            span_oldest = (
                await conn.execute(
                    select(timeline_items.c.order_seq)
                    .where(*boundary_filters)
                    .order_by(
                        timeline_items.c.order_seq.desc(),
                        timeline_items.c.updated_seq.desc(),
                        timeline_items.c.id.desc(),
                    )
                    .offset(span_rows - 1)
                    .limit(1)
                )
            ).scalar_one_or_none()
            if span_oldest is not None and newest_counted < span_oldest:
                return [], False, False

            window_filters = [
                timeline_items.c.session_id == session_id,
                timeline_items.c.parent_item_id.is_(None),
                timeline_items.c.order_seq >= anchor,
            ]
            if before_order_seq is not None:
                # A history window is strictly older than its cursor: rows at
                # or above it are already held by the client, and serving them
                # would also make the budget trim drop the page's oldest rows
                # first — exactly the rows the page exists to fetch.
                window_filters.append(
                    timeline_items.c.order_seq < before_order_seq
                )
            window_statement = (
                select(
                    timeline_items.c.order_seq,
                    timeline_items.c.updated_seq,
                    timeline_items.c.id,
                    case(
                        (stub_eligible, timeline_items.c.stub_json),
                        else_=timeline_items.c.payload_json,
                    ).label("payload"),
                )
                .where(*window_filters)
                .order_by(
                    timeline_items.c.order_seq.desc(),
                    timeline_items.c.updated_seq.desc(),
                    timeline_items.c.id.desc(),
                )
                .limit(span_rows)
            )
            rows = (await conn.execute(window_statement)).mappings().all()
            if not rows:
                return [], False, True

            oldest = rows[-1]
            older_row = (
                await conn.execute(
                    select(literal(1))
                    .where(
                        timeline_items.c.session_id == session_id,
                        timeline_items.c.parent_item_id.is_(None),
                        or_(
                            timeline_items.c.order_seq < oldest["order_seq"],
                            and_(
                                timeline_items.c.order_seq
                                == oldest["order_seq"],
                                timeline_items.c.updated_seq
                                < oldest["updated_seq"],
                            ),
                            and_(
                                timeline_items.c.order_seq
                                == oldest["order_seq"],
                                timeline_items.c.updated_seq
                                == oldest["updated_seq"],
                                timeline_items.c.id < oldest["id"],
                            ),
                        ),
                    )
                    .limit(1)
                )
            ).first()

        items = [
            TimelineItem.model_validate_json(row["payload"])
            for row in reversed(rows)
        ]
        return items, older_row is not None, True

    async def list_children(
        self,
        session_id: str,
        *,
        parent_item_id: str,
        before_order_seq: int | None = None,
        limit: int,
    ) -> tuple[list[TimelineItem], bool]:
        """One page of the child rows of one Agent card, oldest first.

        Ordered by ``(order_seq, updated_seq, id)`` descending and returned
        ascending, matching the other list readers so the client can append
        pages without re-sorting. ``before_order_seq`` pages backwards through
        a card's children and, like the history reader, assumes ``order_seq``
        is unique within the session: the cursor carries only that value, so a
        row tied with the page boundary would be skipped rather than repeated.
        ``has_more`` is raised by the extra row read past ``limit``.
        """

        statement = timeline_items.select().where(
            timeline_items.c.session_id == session_id,
            timeline_items.c.parent_item_id == parent_item_id,
        )
        if before_order_seq is not None:
            statement = statement.where(
                timeline_items.c.order_seq < before_order_seq
            )
        async with self._engine.connect() as conn:
            rows = (
                await conn.execute(
                    statement.order_by(
                        timeline_items.c.order_seq.desc(),
                        timeline_items.c.updated_seq.desc(),
                        timeline_items.c.id.desc(),
                    ).limit(limit + 1)
                )
            ).mappings().all()
        has_more = len(rows) > limit
        items = [TimelineItem.model_validate_json(row["payload_json"]) for row in rows[:limit]]
        items.reverse()
        return items, has_more

    async def list_active_agent_cards(
        self, session_id: str, *, limit: int = 20
    ) -> list[TimelineItem]:
        """The newest non-terminal Agent cards of one session, oldest first.

        P1 of the session-open coverage plan (2026-10-09): the snapshot carries
        these rows beside the timeline page, so a client knows about in-flight
        subagents even when their cards fall outside the (100-item / byte
        budget) windows and no live frame has arrived to announce them. The
        query runs against this table directly — no connector RPC — so it adds
        no first-paint round trip.

        Per-item filter. A row qualifies when its status is non-terminal —
        positively enumerated as ``pending``/``running``/``waiting_approval``,
        mirroring the client's phase mapping (iOS ``SubAgentPhase.from``: those
        three are the live phases, the other four ``TimelineStatus`` values are
        terminal) — and its payload is a tool row whose ``content.kind`` is
        ``agent_call``. Tool rows are the only candidates: every other item
        kind has no agent-card surface.

        Defensive rule (documented, not queried). A card whose *item* status is
        already terminal while its ``content.agents`` still carries a live
        entry (``running`` or the launch receipt ``async_launched`` — the
        connector's ``AGENT_TASK_LIVE_STATUSES``) is still an active card in
        theory and should be kept too: the live entry outranks the item
        status. The engine-side clamp deployed on 2026-10-09 (a terminal fold
        re-opens a card when a *started* task outranks it; stale terminal
        publishes are gated) means such a row should never reach this table.
        That assumption is flagged for red-team review: the positive status
        enumeration cannot see terminal rows, so a terminal-with-live-agents
        row that did land would stay invisible here — and to the capsule this
        query feeds — rather than being returned defensively.

        ``limit`` caps the result at the newest cards by ``order_seq``; the
        rows are returned oldest first, like every other list_* reader here.
        The cap deliberately counts cards, not raw candidate rows: the
        candidates are only the non-terminal tool rows (bounded by construction
        — history-length does not bound them), and a non-agent tool row must
        never push a card out of the list the client promises to carry.
        """

        if limit <= 0:
            return []
        async with self._engine.connect() as conn:
            rows = (
                await conn.execute(
                    timeline_items.select()
                    .where(
                        timeline_items.c.session_id == session_id,
                        timeline_items.c.type == "tool",
                        timeline_items.c.status.in_(
                            sorted(_ACTIVE_AGENT_CARD_STATUSES)
                        ),
                    )
                    .order_by(
                        timeline_items.c.order_seq.desc(),
                        timeline_items.c.updated_seq.desc(),
                        timeline_items.c.id.desc(),
                    )
                )
            ).mappings().all()
        cards = [
            item
            for item in (
                TimelineItem.model_validate_json(row["payload_json"]) for row in rows
            )
            if _is_agent_call_item(item)
        ]
        cards.sort(key=lambda item: (item.orderSeq, item.updatedSeq, item.id))
        return cards[-limit:]

    def _row_values(self, item: TimelineItem) -> dict[str, Any]:
        payload = item.model_dump(exclude_none=True)
        payload_json = _json_dumps(payload)
        payload_bytes = len(payload_json.encode("utf-8"))
        # A main-timeline tool row gets a stub beside its full payload (v2_48):
        # a window reader renders the collapsed line from ``stub_json`` without
        # parsing what can be megabytes of output. Child rows render inside
        # their card and are fetched with it, so they keep no stub.
        stub = None
        if item.type == "tool" and _parent_item_id(item) is None:
            stub = build_stub_content(item.content, payload_bytes)
        stub_json = (
            _json_dumps({**payload, "content": stub}) if stub is not None else None
        )
        return {
            "session_id": item.sessionId,
            "id": item.id,
            "type": item.type,
            "status": item.status,
            "role": item.role,
            "order_seq": item.orderSeq,
            "updated_seq": item.updatedSeq,
            # The Runtime native item id shared by a message's body row and its
            # reasoning rows: the repository's intra-message order invariant
            # (v2_42) groups on it. ``source`` is required, ``itemId`` optional.
            "native_item_id": item.source.itemId,
            # The Runtime native *message* id (``source.nativeMessageId``): the
            # identity a message's tool rows share, mirrored to a column (v2_43)
            # for indexed grouping. ``source`` is required, ``nativeMessageId``
            # optional — absent on rows whose Runtime does not declare it, which
            # then store NULL, exactly as ``native_item_id`` does.
            "native_message_id": item.source.nativeMessageId,
            # The Agent card this row belongs to (``content.parentItemId``),
            # mirrored to a column (v2_47) so the main-timeline window can
            # exclude child rows in SQL before LIMIT. Free-JSON content: only
            # a non-empty string counts; anything else stores NULL.
            "parent_item_id": _parent_item_id(item),
            # Deferred-activity columns (v2_48): ``kind`` and the full payload
            # size for every row, the stub only for main tool rows. A row whose
            # content yields no stub (missing/empty content) keeps both stub
            # columns NULL, exactly as the migration backfill leaves it.
            "kind": content_kind(item.content),
            "payload_bytes": payload_bytes,
            "stub_json": stub_json,
            "stub_version": STUB_VERSION if stub_json is not None else None,
            "item_time": _item_time(item),
            "payload_json": payload_json,
        }


def _item_time(item: TimelineItem) -> str | None:
    values = [value for value in (item.createdAt, item.completedAt, item.updatedAt) if value]
    return max(values) if values else None


def _parent_item_id(item: TimelineItem) -> str | None:
    """The Agent card a row was emitted inside (``content.parentItemId``).

    Total by construction: a payload whose content is not a mapping has no
    parent, and only a non-empty string id counts — the same rule the migration
    backfill applies, so a row written now and one backfilled from an identical
    payload land on the same column value.
    """

    content = item.content
    if not isinstance(content, Mapping):
        return None
    value = content.get("parentItemId")
    return value if isinstance(value, str) and value else None


def _is_agent_call_item(item: TimelineItem) -> bool:
    """Whether a stored tool row renders as an Agent card.

    Same convention as the repository's task-id readers: the content is free
    JSON, and ``content.kind == "agent_call"`` is the only marker (see
    ``repositories/timeline._agent_call_task_ids``). Total by construction: a
    payload whose content is not a mapping is not a card.
    """

    content = item.content
    return isinstance(content, Mapping) and content.get("kind") == "agent_call"
