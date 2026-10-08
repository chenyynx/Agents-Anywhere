from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

# Bumped whenever the history projection starts producing items a stored
# cursor's window cannot retroactively cover. A stored cursor stamped with an
# older version triggers one full rebuild on the session's next sync, which
# is how a projection fix reaches transcripts already past their cursor (the
# 2026-10-05 terminal-task fold was the first such fix: its notices sit behind
# the cursors of every stuck session). Increment for any projection change
# that must be re-applied to existing transcripts.
#
# v4 (2026-10-08): raw-notice ingestion + engine-evidence closure (R1/R2). A
# notice the SDK view dropped now folds from the raw transcript, and a stranded
# card closes from the subagent-transcript oracle. Both reach transcripts whose
# cursors are already past them, so every stored v3 cursor must rebuild once.
HISTORY_PROJECTION_VERSION = 4


@dataclass(frozen=True, slots=True)
class ClaudeHistoryCursor:
    """One stored sync position.

    ``projector_version`` names the history projection that produced the
    timeline items up to this position. Cursors built in code default to the
    current version — only a cursor deserialized from older state can be
    stale — and a stale one makes ``messages_after_cursor`` rebase once.
    """

    last_modified: int | None
    file_size: int | None
    message_count: int
    last_message_uuid: str | None
    projector_version: int | None = HISTORY_PROJECTION_VERSION


# Reasons a sync window ends up covering the whole transcript again.
REBASE_NO_CURSOR = "no_cursor"
REBASE_UUID_DANGLING = "uuid_dangling"
REBASE_CHAIN_REWRITTEN = "chain_rewritten"
REBASE_PROJECTOR_VERSION = "projector_version"
# Reasons the window is an incremental slice of the transcript.
INCREMENTAL_UUID_ANCHORED = "uuid_anchored"
INCREMENTAL_COUNT_ANCHORED = "count_anchored"


@dataclass(frozen=True, slots=True)
class ClaudeHistorySyncWindow:
    """The part of a transcript a stored cursor has not covered yet.

    `rebased` is decided here rather than inferred by the caller from the
    length of the slice. The two happen to coincide today - every branch below
    returns either the whole chain or a strictly shorter one - but a caller
    should not have to re-derive the classification from a side effect of the
    slicing: the day a branch hands back a full-length slice for some other
    reason, an inferred flag follows it silently and flips pending message
    matching to `prefer_latest` with nothing left to record why.
    """

    messages: tuple[Any, ...]
    rebased: bool
    reason: str


def cursor_for(session_info: Any, messages: tuple[Any, ...]) -> ClaudeHistoryCursor:
    last_message_uuid = None
    if messages:
        candidate = _attr(messages[-1], "uuid")
        last_message_uuid = candidate if isinstance(candidate, str) and candidate else None
    return ClaudeHistoryCursor(
        last_modified=_int_attr(session_info, "last_modified", "mtime", "updated_at"),
        file_size=_int_attr(session_info, "file_size"),
        message_count=len(messages),
        last_message_uuid=last_message_uuid,
        projector_version=HISTORY_PROJECTION_VERSION,
    )


def cursor_to_state(cursor: ClaudeHistoryCursor) -> dict[str, Any]:
    return {
        "projectorVersion": cursor.projector_version,
        "fingerprint": {
            "lastModified": cursor.last_modified,
            "fileSize": cursor.file_size,
        },
        "cursor": {
            "messageCount": cursor.message_count,
            "lastMessageUuid": cursor.last_message_uuid,
        },
    }


def cursor_from_state(state: Mapping[str, Any] | None) -> ClaudeHistoryCursor | None:
    if state is None:
        return None
    fingerprint = state.get("fingerprint")
    cursor = state.get("cursor")
    if not isinstance(fingerprint, Mapping) and not isinstance(cursor, Mapping):
        return None
    fingerprint = fingerprint if isinstance(fingerprint, Mapping) else {}
    cursor = cursor if isinstance(cursor, Mapping) else {}
    return ClaudeHistoryCursor(
        last_modified=_optional_int(fingerprint.get("lastModified")),
        file_size=_optional_int(fingerprint.get("fileSize")),
        message_count=_optional_int(cursor.get("messageCount")) or 0,
        last_message_uuid=_optional_json_string(cursor.get("lastMessageUuid")),
        # Absent means the state predates the version stamp, so it is stale
        # (None), never the current default.
        projector_version=_optional_int(state.get("projectorVersion")),
    )


def messages_after_cursor(
    messages: tuple[Any, ...],
    cursor: ClaudeHistoryCursor | None,
) -> ClaudeHistorySyncWindow:
    """Return the part of the chain the cursor has not covered yet.

    A compaction rewrites the chain: the SDK keeps following the summary, so
    every earlier message - including the uuid we stored last time - stops
    being reachable and the stored uuid matches nothing. Slicing by
    `message_count` instead would then start past the end of a now shorter list
    and silently swallow the whole post-compaction transcript, so a dangling
    uuid rebases on the full chain. Re-projecting it is safe: item ids are
    stable per native uuid and the server merges a timeline sync by id, so
    already synced rows are rewritten in place and never dropped.

    `message_count` stays the fallback for transcripts that expose no uuid at
    all, and only when the chain actually grew; a shrunken list means the same
    rewrite happened and needs the same full rebase.

    A missing cursor is the first sync of a session: nothing was covered yet,
    so the window is the whole chain and it counts as a rebase, exactly like the
    sync that follows a rewrite.

    A cursor stamped with an older projection version is the same kind of
    stale: the window it describes may already have been published, but the
    items it produced no longer match what today's projector would emit (the
    terminal task fold is the first such change), so the whole chain is
    re-projected once and the cursor lands stamped with the current version.
    """
    if cursor is None:
        return ClaudeHistorySyncWindow(
            messages=messages,
            rebased=True,
            reason=REBASE_NO_CURSOR,
        )
    if cursor.projector_version != HISTORY_PROJECTION_VERSION:
        return ClaudeHistorySyncWindow(
            messages=messages,
            rebased=True,
            reason=REBASE_PROJECTOR_VERSION,
        )
    if cursor.last_message_uuid:
        for index, message in enumerate(messages):
            if _attr(message, "uuid") == cursor.last_message_uuid:
                return ClaudeHistorySyncWindow(
                    messages=messages[index + 1 :],
                    rebased=False,
                    reason=INCREMENTAL_UUID_ANCHORED,
                )
        return ClaudeHistorySyncWindow(
            messages=messages,
            rebased=True,
            reason=REBASE_UUID_DANGLING,
        )
    if 0 < cursor.message_count < len(messages):
        return ClaudeHistorySyncWindow(
            messages=messages[cursor.message_count :],
            rebased=False,
            reason=INCREMENTAL_COUNT_ANCHORED,
        )
    return ClaudeHistorySyncWindow(
        messages=messages,
        rebased=True,
        reason=REBASE_CHAIN_REWRITTEN,
    )


def _int_attr(item: Any, *names: str) -> int | None:
    for name in names:
        value = _attr(item, name)
        parsed = _optional_int(value)
        if parsed is not None:
            return parsed
    return None


def _attr(item: Any, name: str) -> Any:
    if isinstance(item, Mapping):
        return item.get(name)
    return getattr(item, name, None)


def _optional_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            return None
    return None


def _optional_json_string(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None
