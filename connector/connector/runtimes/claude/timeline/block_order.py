"""A message's real content-block order, read from the CLI's request ledger.

The transcript writes ONE content block per assistant line (a thinking line, a
tool_use line, a text line — all sharing the assistant message id), so line
order is block *completion* order, not the message's content order. On the
OpenAI-format model channel a tool call completes before the text it follows,
and deriving the absolute index from line order inverted every text+tool
message: the server then moved the tool row above the body (pp 2026-11-20).

The assembled message — the exact ``content`` array the CLI sent back to the
model — is persisted in ``api-request-blob`` lines. This module reads those
ledgers and resolves, per assistant message id, each block's absolute index.

Declaration rule (宁缺勿假): a message gets an order only from a blob that was
attributed to it through a unique anchor (a tool_use id, or a thinking block's
signature / text hash). No blob, an unattributable blob (no anchor of ours), a
blob carrying anchors of two different messages, or two conflicting blobs for
one message all yield NO order — the caller then declares nothing and the
server falls back to RBT. A guessed index is never produced.

Scale note: these indexes use the same absolute content-array scale as
``source.contentBlockIndex`` (reasoning/body/tool), NOT the tool-only ordinal
``source.blockIndex``.
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass

#: One content block's fingerprint: ``(kind, key)`` with kind in
#: ``{"tool", "thinking", "text"}``.
BlockKey = tuple[str, str]

_TEXT_BLOCK_TYPES = frozenset({"text"})
_THINKING_BLOCK_TYPES = frozenset({"thinking", "reasoning"})


def text_key(text: str) -> str:
    """Stable fingerprint of a text block's content."""

    return hashlib.sha1(text.encode("utf-8", "surrogatepass")).hexdigest()


def thinking_key(signature: object, text: object) -> str | None:
    """Fingerprint of a thinking block.

    The text hash comes first on purpose: the SDK block view does not expose
    the ledger's ``signature`` field, and the two sides must derive the SAME
    key. The signature is only the fallback for a block the ledger wrote
    without text (a redacted/empty thinking block then simply stays
    unresolvable — nothing is guessed).
    """

    if isinstance(text, str) and text:
        return f"txt:{text_key(text)}"
    if isinstance(signature, str) and signature:
        return f"sig:{signature}"
    return None


def tool_key(tool_use_id: str) -> str:
    """Fingerprint of a tool_use block: the Runtime-native call id."""

    return tool_use_id


@dataclass(frozen=True, slots=True)
class BlobLedger:
    """One assembled assistant message, in the order its ``content`` array declares."""

    blocks: tuple[BlockKey, ...]


@dataclass(frozen=True, slots=True)
class MessageBlockOrder:
    """A message's block fingerprints mapped to their absolute content index."""

    by_key: Mapping[BlockKey, int]
    first_text_index: int | None

    def index_for(self, kind: str, key: str | None) -> int | None:
        if key is None:
            return None
        return self.by_key.get((kind, key))


def blob_ledgers(lines: Iterable[str]) -> tuple[BlobLedger, ...]:
    """Every assistant ``api-request-blob`` line as a block ledger, in file order.

    Lines are prefiltered on the record type before JSON parsing, so a
    transcript without the diagnostics costs one substring scan per line.
    Malformed lines contribute nothing (a transcript is data, never a
    contract).
    """

    ledgers: list[BlobLedger] = []
    for line in lines:
        if '"api-request-blob"' not in line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict) or record.get("type") != "api-request-blob":
            continue
        message = record.get("message")
        if not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        content = message.get("content")
        if not isinstance(content, list):
            continue
        blocks: list[BlockKey] = []
        for block in content:
            if not isinstance(block, dict):
                continue
            block_type = block.get("type")
            if block_type == "tool_use":
                call_id = block.get("id")
                if isinstance(call_id, str) and call_id:
                    blocks.append(("tool", tool_key(call_id)))
            elif block_type in _THINKING_BLOCK_TYPES:
                key = thinking_key(
                    block.get("signature"),
                    block.get("thinking") or block.get("text"),
                )
                if key is not None:
                    blocks.append(("thinking", key))
            elif block_type in _TEXT_BLOCK_TYPES:
                text = block.get("text")
                if isinstance(text, str) and text:
                    blocks.append(("text", text_key(text)))
        if blocks:
            ledgers.append(BlobLedger(tuple(blocks)))
    return tuple(ledgers)


def resolve_message_orders(
    anchors: Mapping[BlockKey, str],
    ledgers: Sequence[BlobLedger],
) -> dict[str, MessageBlockOrder | None]:
    """Attribute ledgers to message ids and return each message's real order.

    ``anchors`` maps a block fingerprint to the assistant message id that
    declares it (built by the caller from the SDK message view). A ledger is
    attributed only when exactly ONE message id owns any of its anchors —
    zero means we cannot tie it to a message we project, more than one means
    the ledger is contradictory. Both are dropped.

    A message with several attributed ledgers keeps an order only when they
    are identical; differing ledgers are recorded as ``None`` (conflict).
    Messages with no attributed ledger are absent from the result — the
    caller declares nothing for them.
    """

    attributed: dict[str, list[BlobLedger]] = {}
    for ledger in ledgers:
        owners = {anchors[block] for block in ledger.blocks if block in anchors}
        if len(owners) != 1:
            continue
        attributed.setdefault(next(iter(owners)), []).append(ledger)

    orders: dict[str, MessageBlockOrder | None] = {}
    for message_id, message_ledgers in attributed.items():
        shapes = {ledger.blocks for ledger in message_ledgers}
        if len(shapes) != 1:
            orders[message_id] = None
            continue
        blocks = next(iter(shapes))
        by_key: dict[BlockKey, int] = {}
        first_text_index: int | None = None
        for index, (kind, key) in enumerate(blocks):
            by_key.setdefault((kind, key), index)
            if kind == "text" and first_text_index is None:
                first_text_index = index
        orders[message_id] = MessageBlockOrder(
            by_key=by_key,
            first_text_index=first_text_index,
        )
    return orders
