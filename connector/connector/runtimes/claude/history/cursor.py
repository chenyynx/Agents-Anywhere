from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True, slots=True)
class ClaudeHistoryCursor:
    last_modified: int | None
    file_size: int | None
    message_count: int
    last_message_uuid: str | None


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
    )


def cursor_to_state(cursor: ClaudeHistoryCursor) -> dict[str, Any]:
    return {
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
    )


def messages_after_cursor(
    messages: tuple[Any, ...],
    cursor: ClaudeHistoryCursor,
) -> tuple[Any, ...]:
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
    """
    if cursor.last_message_uuid:
        for index, message in enumerate(messages):
            if _attr(message, "uuid") == cursor.last_message_uuid:
                return messages[index + 1 :]
        return messages
    if 0 < cursor.message_count < len(messages):
        return messages[cursor.message_count :]
    return messages


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
